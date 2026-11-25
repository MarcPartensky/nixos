"""taskq-mcp : serveur MCP (stdio) pour la file de taches de tower.

Memes operations que le CLI `taskq` et la webui : poser, lire, expliquer,
piloter, journaliser. Les chemins psql/journalctl et la base viennent de
l'environnement (poses par le module services/taskq) ; zero dependance en
dehors du SDK `mcp`.

Outils : submit, list_tasks, show, why, metrics, state, hosts, control,
logs, digest, webui. Les actions ecrivent les memes lignes `decisions` que le
CLI et la webui (actor "mcp").
"""

import json
import os
import re
import subprocess

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

DB = os.environ.get("TASKQ_DATABASE_URL", "postgresql://taskq@127.0.0.1/taskq")
PSQL = os.environ.get("TASKQ_PSQL", "psql")
JOURNALCTL = os.environ.get("TASKQ_JOURNALCTL", "journalctl")
WEBUI_URL = os.environ.get("TASKQ_WEBUI_URL", "https://taskq.marcpartensky.com")
ACTOR = "mcp"
UNIT_RE = re.compile(r"^[A-Za-z0-9@_.-]+$")

mcp = MCPServer("taskq")


# --------------------------------------------------------------------- helpers

def psql(sql: str, tuples: bool = True) -> str:
    args = [PSQL, DB, "-v", "ON_ERROR_STOP=1", "-q"] + (["-tA"] if tuples else []) + ["-c", sql]
    out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"psql: {out.stderr.strip()[:300]}")
    return out.stdout.strip()


def one(sql: str):
    txt = psql(sql)
    return json.loads(txt) if txt else None


def rows(sql: str) -> list:
    return one(f"select coalesce(json_agg(row_to_json(x)), '[]') from ({sql}) x") or []


def exec_(sql: str) -> None:
    psql(sql, tuples=False)


def q(v) -> str:
    if v is None:
        return "null"
    return "'" + str(v).replace("'", "''") + "'"


def metrics_blob() -> tuple[dict, dict]:
    m = one("select value from state where key='last_metrics'") or {}
    return m, (m.get("budget") or {})


# ---------------------------------------------------------------------- tools

@mcp.tool()
def submit(
    target: str,
    kind: str = "",
    key: str = "",
    cpu_class: str = "medium",
    mem_min_mb: int = 512,
    llm_cost: str = "none",
    paid_cap_cents: int = 0,
    est_minutes: int = 0,
    priority: int = 100,
    not_before_minutes: int = 0,
    deadline_minutes: int = 0,
    while_busy: bool = False,
    needs_absence: bool = False,
    requires_gpu: bool = False,
    run_as: str = "hermes",
    workdir: str = "",
    env: dict | None = None,
    by: str = "mcp",
) -> dict:
    """Pose une tache dans la file taskq (le dispatcher decide QUAND la lancer).

    kind : "systemd_unit" (defaut si target finit par .service) ou "command"
    (commande shell, lancee par systemd-run). cpu_class : light|medium|heavy.
    llm_cost : none|free|paid (paid consomme le budget payant du jour).
    needs_absence : ne tourne que quand marc n'est pas connecte.
    deadline_minutes : force le demarrage quand l'echeance approche.
    key : cle d'idempotence (une seule ligne par cle).
    """
    if cpu_class not in ("light", "medium", "heavy"):
        raise ValueError("cpu_class doit etre light|medium|heavy")
    if llm_cost not in ("none", "free", "paid"):
        raise ValueError("llm_cost doit etre none|free|paid")
    if not kind:
        kind = "systemd_unit" if target.endswith(".service") else "command"
    cols = {
        "key": q(key or None),
        "kind": q(kind),
        "target": q(target),
        "run_as": q(run_as),
        "workdir": q(workdir or None),
        "cpu_class": q(cpu_class),
        "mem_min_mb": str(int(mem_min_mb)),
        "llm_cost": q(llm_cost),
        "est_minutes": str(int(est_minutes)) if est_minutes else "null",
        "paid_cap_cents": str(int(paid_cap_cents)),
        "priority": str(int(priority)),
        "while_busy": "true" if while_busy else "false",
        "needs_absence": "true" if needs_absence else "false",
        "requires_gpu": "true" if requires_gpu else "false",
        "not_before": f"now() + interval '{int(not_before_minutes)} minutes'" if not_before_minutes else "now()",
        "deadline": f"now() + interval '{int(deadline_minutes)} minutes'" if deadline_minutes else "null",
        "env": q(json.dumps(env or {})) + "::jsonb",
        "created_by": q(by),
    }
    conflict = "on conflict (key) do update set updated_at = now() returning id" if key else "returning id"
    tid = psql(f"insert into tasks ({', '.join(cols)}) values ({', '.join(cols.values())}) {conflict}")
    exec_("insert into decisions (task_id, action, actor, reason) values "
          f"({tid}, 'submit', {q(ACTOR)}, {q(f'{kind} {target} ({cpu_class}, llm {llm_cost})')})")
    return {"id": int(tid), "status": "queued", "kind": kind, "target": target}


@mcp.tool()
def list_tasks(status: str = "", limit: int = 25) -> list:
    """Liste les taches de la file. status : queued|running|done|failed|blocked|... (vide = tout)."""
    where = f"where status = {q(status)}" if status else ""
    return rows(
        "select id, status, priority, cpu_class, llm_cost, left(target, 60) as target,"
        " to_char(created_at, 'HH24:MI') as cree, to_char(started_at, 'HH24:MI') as demarre,"
        " minutes_taken, attempts, exit_code, left(coalesce(note, ''), 80) as note"
        f" from queue {where} limit {int(limit)}"
    )


@mcp.tool()
def show(task_id: int) -> dict:
    """Detail d'une tache : champs complets + 10 dernieres decisions."""
    t = one(f"select row_to_json(x) from (select * from tasks where id = {int(task_id)}) x")
    if not t:
        raise ValueError(f"tache {task_id} inconnue")
    d = rows(
        "select to_char(at, 'HH24:MI:SS') as at, action, actor, left(reason, 120) as reason"
        f" from decisions where task_id = {int(task_id)} order by at desc limit 10"
    )
    return {"task": t, "decisions": d}


@mcp.tool()
def why(task_id: int = 0) -> dict:
    """Pourquoi la file est dans cet etat : metriques machine/budget +, si un id
    est donne, les dernieres raisons de report/demarrage de cette tache."""
    m, b = metrics_blob()
    out = {
        "paused": (one("select value from state where key='paused'") or "false") in ("true", True),
        "load1": m.get("load1"), "threads": m.get("threads"),
        "mem_avail_mb": m.get("mem_avail_mb"), "mem_total_mb": m.get("mem_total_mb"),
        "marc_busy": m.get("marc_busy"), "marc_present": m.get("marc_present"),
        "marc_connected": m.get("marc_connected"), "marc_connected_why": m.get("marc_connected_why"),
        "local_model_running": m.get("local_model_running"), "gpu": m.get("gpu") or None,
        "budget_left_cents": b.get("left_cents"), "budget_cap_cents": b.get("cap_cents"),
        "at": m.get("at"),
    }
    if task_id:
        out["reasons"] = rows(
            "select to_char(at, 'HH24:MI') as at, action, left(reason, 140) as reason"
            f" from decisions where task_id = {int(task_id)} and action in ('defer','start','finish','fail','block')"
            " order by at desc limit 5"
        )
    return out


@mcp.tool()
def metrics() -> dict:
    """Etat machine vu par le dispatcher (load, RAM, marc, GPU, modele local, budget payant)."""
    m, b = metrics_blob()
    return {"metrics": m, "budget": b}


@mcp.tool()
def state() -> dict:
    """Etat deterministe (compteurs par statut, pause, budget) : concu pour du polling rapide."""
    counts = {r["status"]: r["n"] for r in rows("select status, count(*) as n from tasks group by status")}
    m, b = metrics_blob()
    paused = (one("select value from state where key='paused'") or "false") in ("true", True)
    unacked = int(psql("select count(*) from decisions where not notified") or "0")
    return {"paused": paused, "counts": counts, "unacked_decisions": unacked,
            "budget_left_cents": b.get("left_cents"), "marc_busy": m.get("marc_busy")}


@mcp.tool()
def hosts() -> list:
    """Flotte : workers enregistres (name, capabilities, metriques, heartbeat, quarantaine).
    Vide tant que la flotte n'est pas branchee ; tower execute en local."""
    return rows(
        "select name, caps, metrics, enabled, quarantined_until::text as quarantined_until,"
        " left(coalesce(note, ''), 120) as note, heartbeat::text as heartbeat,"
        " coalesce(round(extract(epoch from (now() - heartbeat)))::int, -1) as silent_seconds"
        " from hosts order by name"
    )


@mcp.tool()
def control(action: str, task_id: int = 0, reason: str = "") -> dict:
    """Pilote la file : pause | resume | unblock | ack (marque les decisions comme lues),
    retry (id) | cancel (id). Meme SQL que le CLI, trace dans `decisions`."""
    if action == "pause":
        exec_("insert into state (key, value) values ('paused', 'true'::jsonb)"
              " on conflict (key) do update set value = 'true'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('pause', {q(ACTOR)}, 'file en pause (mcp)')")
    elif action == "resume":
        exec_("insert into state (key, value) values ('paused', 'false'::jsonb)"
              " on conflict (key) do update set value = 'false'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('resume', {q(ACTOR)}, 'file relancee (mcp)')")
    elif action == "unblock":
        exec_("update tasks set status='queued', note='debloque', updated_at=now() where status='blocked'")
        exec_(f"insert into decisions (action, actor, reason) values ('unblock', {q(ACTOR)}, 'taches bloquees remises en file (mcp)')")
    elif action == "ack":
        n = psql("update decisions set notified = true where not notified returning id")
        return {"ok": True, "action": action, "acked": n.count("\n") + 1 if n else 0}
    elif action == "retry":
        if not task_id:
            raise ValueError("retry exige task_id")
        exec_(f"update tasks set status='queued', not_before=now(), attempts=0, updated_at=now() where id={int(task_id)}")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(task_id)}, 'note', {q(ACTOR)}, 'remise en file (mcp)')")
    elif action == "cancel":
        if not task_id:
            raise ValueError("cancel exige task_id")
        msg = reason or "annule par le mcp"
        exec_(f"update tasks set status='cancelled', finished_at=now(), updated_at=now(), note={q(msg)}"
              f" where id={int(task_id)} and status in ('queued','blocked')")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(task_id)}, 'skip', {q(ACTOR)}, {q(msg)})")
    else:
        raise ValueError(f"action inconnue: {action}")
    return {"ok": True, "action": action}


@mcp.tool()
def logs(unit: str = "", task_id: int = 0, lines: int = 50) -> str:
    """Journal systemd d'une tache (par task_id, ou directement le nom d'une unite).
    Utile pour voir ou en est un scrape/ingest en cours."""
    if not unit and task_id:
        t = one(f"select row_to_json(x) from (select unit, target, kind from tasks where id={int(task_id)}) x")
        if not t:
            raise ValueError(f"tache {task_id} inconnue")
        unit = t.get("unit") or t.get("target")
    if not unit or not UNIT_RE.match(unit):
        raise ValueError("unite invalide")
    out = subprocess.run(
        [JOURNALCTL, "-u", unit, "-n", str(max(1, min(int(lines), 500))), "--no-pager"],
        capture_output=True, text=True, timeout=30,
    )
    txt = (out.stdout or out.stderr or "").strip()
    return txt[-6000:] if txt else "(journal vide)"


@mcp.tool()
def digest(ack: bool = False) -> dict:
    """Resume pour marc : decisions non notifiees + file courante. ack=True marque
    les decisions comme lues (a faire quand le resume a ete delivre)."""
    m, b = metrics_blob()
    pend = rows("select id, action, left(coalesce(reason, ''), 90) as reason, to_char(at, 'HH24:MI') as at"
                " from decisions where not notified order by at limit 30")
    file_ = rows("select id, status, priority, left(target, 40) as target, left(coalesce(note, ''), 50) as note"
                 " from queue where status in ('queued','running','failed','blocked') limit 20")
    out = {"machine": {"load1": m.get("load1"), "threads": m.get("threads"),
                       "mem_avail_mb": m.get("mem_avail_mb"), "marc_busy": m.get("marc_busy"),
                       "budget_left_cents": b.get("left_cents")},
           "unnotified_decisions": pend, "queue": file_}
    if ack:
        n = psql("update decisions set notified = true where not notified returning id")
        out["acked"] = n.count("\n") + 1 if n else 0
    return out


@mcp.tool()
def webui() -> dict:
    """URL de la webui taskq (SSO Pangolin) + etat compact de la file."""
    counts = {r["status"]: r["n"] for r in rows("select status, count(*) as n from tasks group by status")}
    return {"url": WEBUI_URL, "counts": counts,
            "hint": "la page poll /api/state toutes les 5 s ; actions pause/retry/cancel incluses"}


if __name__ == "__main__":
    mcp.run()
