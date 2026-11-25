"""taskq-mcp: MCP server (stdio) for tower's task queue.

Same operations as the `taskq` CLI and the webui: submit, read, explain,
drive, log. The psql/journalctl paths and the database come from
the environment (set by the services/taskq module); zero dependency beyond
the `mcp` SDK.

Tools: submit, list_tasks, show, why, metrics, state, hosts, control,
logs, digest, webui. Actions write the same `decisions` rows as the
CLI and the webui (actor "mcp").
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
    """Submit a task to the taskq queue (the dispatcher decides WHEN to run it).

    kind: "systemd_unit" (default if target ends with .service) or "command"
    (shell command, launched by systemd-run). cpu_class: light|medium|heavy.
    llm_cost: none|free|paid (paid uses the day's paid budget).
    needs_absence: only runs when marc is not connected.
    deadline_minutes: forces the start when the deadline approaches.
    key: idempotency key (a single row per key).
    """
    if cpu_class not in ("light", "medium", "heavy"):
        raise ValueError("cpu_class must be light|medium|heavy")
    if llm_cost not in ("none", "free", "paid"):
        raise ValueError("llm_cost must be none|free|paid")
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
    """List the tasks in the queue. status: queued|running|done|failed|blocked|... (empty = all)."""
    where = f"where status = {q(status)}" if status else ""
    return rows(
        "select id, status, priority, cpu_class, llm_cost, left(target, 60) as target,"
        " to_char(created_at, 'HH24:MI') as cree, to_char(started_at, 'HH24:MI') as demarre,"
        " minutes_taken, attempts, exit_code, left(coalesce(note, ''), 80) as note"
        f" from queue {where} limit {int(limit)}"
    )


@mcp.tool()
def show(task_id: int) -> dict:
    """Task detail: full fields + last 10 decisions."""
    t = one(f"select row_to_json(x) from (select * from tasks where id = {int(task_id)}) x")
    if not t:
        raise ValueError(f"unknown task {task_id}")
    d = rows(
        "select to_char(at, 'HH24:MI:SS') as at, action, actor, left(reason, 120) as reason"
        f" from decisions where task_id = {int(task_id)} order by at desc limit 10"
    )
    return {"task": t, "decisions": d}


@mcp.tool()
def why(task_id: int = 0) -> dict:
    """Why the queue is in this state: machine/budget metrics +, if an id
    is given, the latest defer/start reasons for that task."""
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
    """Machine state seen by the dispatcher (load, RAM, marc, GPU, local model, paid budget)."""
    m, b = metrics_blob()
    return {"metrics": m, "budget": b}


@mcp.tool()
def state() -> dict:
    """Deterministic state (counts per status, pause, budget): built for fast polling."""
    counts = {r["status"]: r["n"] for r in rows("select status, count(*) as n from tasks group by status")}
    m, b = metrics_blob()
    paused = (one("select value from state where key='paused'") or "false") in ("true", True)
    unacked = int(psql("select count(*) from decisions where not notified") or "0")
    return {"paused": paused, "counts": counts, "unacked_decisions": unacked,
            "budget_left_cents": b.get("left_cents"), "marc_busy": m.get("marc_busy")}


@mcp.tool()
def hosts() -> list:
    """Fleet: registered workers (name, capabilities, metrics, heartbeat, quarantine).
    Empty while the fleet is not wired up; tower runs locally."""
    return rows(
        "select name, caps, metrics, enabled, quarantined_until::text as quarantined_until,"
        " left(coalesce(note, ''), 120) as note, heartbeat::text as heartbeat,"
        " coalesce(round(extract(epoch from (now() - heartbeat)))::int, -1) as silent_seconds"
        " from hosts order by name"
    )


@mcp.tool()
def control(action: str, task_id: int = 0, reason: str = "") -> dict:
    """Drive the queue: pause | resume | unblock | ack (marks decisions as read),
    retry (id) | cancel (id). Same SQL as the CLI, traced in `decisions`."""
    if action == "pause":
        exec_("insert into state (key, value) values ('paused', 'true'::jsonb)"
              " on conflict (key) do update set value = 'true'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('pause', {q(ACTOR)}, 'queue paused (mcp)')")
    elif action == "resume":
        exec_("insert into state (key, value) values ('paused', 'false'::jsonb)"
              " on conflict (key) do update set value = 'false'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('resume', {q(ACTOR)}, 'queue resumed (mcp)')")
    elif action == "unblock":
        exec_("update tasks set status='queued', note='unblocked', updated_at=now() where status='blocked'")
        exec_(f"insert into decisions (action, actor, reason) values ('unblock', {q(ACTOR)}, 'blocked tasks requeued (mcp)')")
    elif action == "ack":
        n = psql("update decisions set notified = true where not notified returning id")
        return {"ok": True, "action": action, "acked": n.count("\n") + 1 if n else 0}
    elif action == "retry":
        if not task_id:
            raise ValueError("retry requires task_id")
        exec_(f"update tasks set status='queued', not_before=now(), attempts=0, updated_at=now() where id={int(task_id)}")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(task_id)}, 'note', {q(ACTOR)}, 'requeued (mcp)')")
    elif action == "cancel":
        if not task_id:
            raise ValueError("cancel requires task_id")
        msg = reason or "cancelled by mcp"
        exec_(f"update tasks set status='cancelled', finished_at=now(), updated_at=now(), note={q(msg)}"
              f" where id={int(task_id)} and status in ('queued','blocked')")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(task_id)}, 'skip', {q(ACTOR)}, {q(msg)})")
    else:
        raise ValueError(f"unknown action: {action}")
    return {"ok": True, "action": action}


@mcp.tool()
def logs(unit: str = "", task_id: int = 0, lines: int = 50) -> str:
    """Systemd log of a task (by task_id, or directly the unit name).
    Useful to see where an ongoing scrape/ingest stands."""
    if not unit and task_id:
        t = one(f"select row_to_json(x) from (select unit, target, kind from tasks where id={int(task_id)}) x")
        if not t:
            raise ValueError(f"unknown task {task_id}")
        unit = t.get("unit") or t.get("target")
    if not unit or not UNIT_RE.match(unit):
        raise ValueError("invalid unit")
    out = subprocess.run(
        [JOURNALCTL, "-u", unit, "-n", str(max(1, min(int(lines), 500))), "--no-pager"],
        capture_output=True, text=True, timeout=30,
    )
    txt = (out.stdout or out.stderr or "").strip()
    return txt[-6000:] if txt else "(empty journal)"


@mcp.tool()
def digest(ack: bool = False) -> dict:
    """Summary for marc: unnotified decisions + current queue. ack=True marks
    the decisions as read (do this once the summary has been delivered)."""
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
    """taskq webui URL (Pangolin SSO) + compact queue state."""
    counts = {r["status"]: r["n"] for r in rows("select status, count(*) as n from tasks group by status")}
    return {"url": WEBUI_URL, "counts": counts,
            "hint": "the page polls /api/state every 5 s; pause/retry/cancel actions included"}


if __name__ == "__main__":
    mcp.run()
