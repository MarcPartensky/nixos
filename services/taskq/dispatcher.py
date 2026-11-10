#!/usr/bin/env python3
"""taskq dispatcher.

24/7 scheduler for tower. It owns one question: *may this task run right now,
and if not, when?* It watches the machine (load, RAM, GPU, whether marc is
using the box -- cpu, tty, Hermes activity, plus les fenetres sommeil/travail
de presence.py), the queue, and the money (paid LLM budget), then starts tasks
when they fit -- and writes down why it did or did not.

No third-party dependency: metrics from /proc, queue access through psql.

Usage:
  dispatcher.py            # loop forever (systemd service)
  dispatcher.py --once     # one pass, human-readable report on stdout
  dispatcher.py --dry-run  # decide and log, start nothing
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import presence  # meme dossier que ce script (copie par le module Nix)

DB = os.environ.get("TASKQ_DATABASE_URL", "postgresql://taskq@127.0.0.1/taskq")
WINNIE_DB = os.environ.get("TASKQ_WINNIE_DATABASE_URL", "")
POLL_SECONDS = int(os.environ.get("TASKQ_POLL_SECONDS", "20"))
MARC_UID = int(os.environ.get("TASKQ_MARC_UID") or "1000")  # vide -> 1000
RESERVE_MB = int(os.environ.get("TASKQ_RESERVE_MB", "4096"))
BUSY_CPU_PCT = float(os.environ.get("TASKQ_BUSY_CPU_PCT", "25"))
# Fenetre d'inactivite (minutes) pour `needs_absence` : aucune interaction de
# marc (shell ssh/local, session Hermes interactive, web UI) depuis ce delai
# => les taches de fond peuvent demarrer; sa premiere interaction les coupe.
# S'y ajoutent les fenetres d'absence previsionnelles (sommeil / travail,
# presence.py) et une hysteresis de calme pour le redemarrage en fenetre.
ABSENCE_MINUTES = int(os.environ.get("TASKQ_ABSENCE_MINUTES", "15"))
WINDOW_CALM_SECONDS = int(os.environ.get("TASKQ_WINDOW_CALM_SECONDS", "90"))
HERMES_STATE_DB = os.environ.get("TASKQ_HERMES_STATE_DB", "/var/lib/hermes/.hermes/state.db")
PRESENCE_CFG = presence.load_config()
# Dernier instant ou marc touchait vraiment la machine (cpu ou tty), None au
# demarrage : sert a exiger WINDOW_CALM_SECONDS de calme avant de relancer une
# tache de fond dans une fenetre d'absence (l'activite d'un telephone au
# bureau ne compte pas, seul l'usage de tower compte).
_calm: dict = {"last_busy": None}
# Load ceilings, per class, as a fraction of the thread count.
LOAD_CEILING = {"light": 1.2, "medium": 0.9, "heavy": 0.6}
GPU = None  # resolved lazily: name of a usable GPU, or "" when there is none


def log(msg: str) -> None:
    print(f"{dt.datetime.now().strftime('%H:%M:%S')} {msg}", flush=True)


# --------------------------------------------------------------------------- db

def psql(sql: str, db: str = DB, tuples: bool = True) -> str:
    args = ["psql", db, "-v", "ON_ERROR_STOP=1", "-q"]
    if tuples:
        args.append("-tA")
    args += ["-c", sql]
    out = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(f"psql: {out.stderr.strip()}")
    return out.stdout.strip()


def one(sql: str, db: str = DB):
    txt = psql(sql, db)
    return json.loads(txt) if txt else None


def exec_(sql: str, db: str = DB) -> None:
    psql(sql, db, tuples=False)


def q(value) -> str:
    """Literal SQL pour une chaine (echappe les quotes)."""
    if value is None:
        return "null"
    return "'" + str(value).replace("'", "''") + "'"


def decision(task_id, action: str, reason: str, metrics=None, actor="dispatcher") -> None:
    exec_(
        "insert into decisions (task_id, action, actor, reason, metrics) values ("
        f"{task_id if task_id is not None else 'null'}, {q(action)}, {q(actor)}, "
        f"{q(reason[:500])}, {q(json.dumps(metrics or {}))}::jsonb)"
    )
    log(f"decision {action}: {reason}")


# ---------------------------------------------------------------------- metrics

_prev_cpu: dict = {"at": 0.0, "samples": {}}


def _jiffies(pid: int):
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    rp = stat.rfind(")")
    fields = stat[rp + 2:].split()
    return int(fields[11]) + int(fields[12])  # utime + stime


def marc_cpu_pct(now_sample: dict, now: float) -> float:
    """CPU % (une unite = un coeur) consomme par les process de marc depuis le
    dernier echantillon."""
    pct = 0.0
    if _prev_cpu["at"]:
        dt_s = max(now - _prev_cpu["at"], 1e-3)
        hz = os.sysconf("SC_CLK_TCK")
        delta = 0
        for pid, jif in now_sample.items():
            old = _prev_cpu["samples"].get(pid)
            if old is not None and jif >= old:
                delta += jif - old
        pct = 100.0 * delta / hz / dt_s
    _prev_cpu.update(at=now, samples=now_sample)
    return pct


def proc_scan():
    """Retourne (jiffies de marc, kasm actif, ollama actif, nom du GPU utilisable)."""
    marc, kasm, ollama = {}, False, False
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            owner = entry.stat().st_uid
        except OSError:
            continue
        if owner == MARC_UID:
            j = _jiffies(int(entry.name))
            if j is not None:
                marc[entry.name] = j
        if owner in (MARC_UID, 0):  # Xvnc tourne chez marc, ollama chez ollama
            try:
                cmd = (entry / "cmdline").read_bytes().decode(errors="replace")
            except OSError:
                continue
            if "Xvnc" in cmd or "kasmvnc" in cmd.lower():
                kasm = True
            if "llama-server" in cmd or "ollama" in cmd:
                ollama = True
    return marc, kasm, ollama


def gpu_name() -> str:
    global GPU
    if GPU is None:
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True, text=True, timeout=10,
            )
            GPU = out.stdout.strip().splitlines()[0] if out.returncode == 0 and out.stdout.strip() else ""
        except (OSError, subprocess.SubprocessError):
            GPU = ""
    return GPU


def marc_tty_active() -> str | None:
    """Un shell de marc recemment utilise (ssh depuis le Mac, tty local)."""
    try:
        out = subprocess.run(["who", "-u"], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return "who indisponible (suppose connecte)"
    for line in out.splitlines():
        f = line.split()
        if len(f) < 5 or f[0] != "marc":
            continue
        idle = f[4]
        if idle == ".":
            return "shell marc actif a l'instant"
        if ":" in idle:
            try:
                h, m = idle.split(":")[:2]
                if int(h) * 60 + int(m) < ABSENCE_MINUTES:
                    return f"shell marc utilise il y a {idle}"
            except ValueError:
                continue
    return None


def hermes_interactive_active() -> str | None:
    """Une session Hermes interactive recente (app desktop, CLI, matrix).

    Les sources autonomes (cron, oneshot, subagent) ne comptent pas : elles
    tournent sans marc. Deux lectures independantes (sessions + messages
    joints aux sources interactives) : un lecteur WAL qui ne verrait qu'un
    etat perime ne peut pas mettre les deux a zero en meme temps (vecu : un
    `sqlite3 -readonly` a renvoye 0 pendant que 552 messages s'ecrivaient).
    Toute erreur de lecture => 'connecte' : on ne lance jamais une tache de
    fond dans le doute.
    """
    since = time.time() - ABSENCE_MINUTES * 60
    queries = (
        "select count(*) from sessions where archived=0 "
        "and source not in ('cron','oneshot','subagent') and last_activity_at > ?",
        "select count(*) from messages m join sessions s on s.id = m.session_id "
        "where s.archived=0 and s.source not in ('cron','oneshot','subagent') "
        "and m.timestamp > ?",
    )
    hits = []
    try:
        con = sqlite3.connect(HERMES_STATE_DB, timeout=5)
        try:
            for sql in queries:
                row = con.execute(sql, (since,)).fetchone()
                hits.append(int(row[0]) if row else 0)
        finally:
            con.close()
    except sqlite3.Error as e:
        return f"etat hermes illisible ({e}) (suppose connecte)"
    if max(hits) > 0:
        return f"activite hermes recente < {ABSENCE_MINUTES} min (sessions {hits[0]}, messages {hits[1]})"
    return None


def webui_active() -> str | None:
    """Un POST recent sur la web UI Hermes : une action de marc.

    Le GET /login du probe (toutes les 30 s) ne compte pas.
    """
    try:
        out = subprocess.run(
            ["journalctl", "-u", "hermes-webui", f"--since=-{ABSENCE_MINUTES} min",
             "-o", "cat", "--no-pager"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return "requete POST recente sur hermes-webui" if '"method": "POST"' in out else None


def read_overrides() -> dict:
    """Overrides par date de la config presence (table state)."""
    value = one("select value from state where key='presence_overrides'")
    return value if isinstance(value, dict) else {}


def read_metrics() -> dict:
    now = time.time()
    threads = os.cpu_count() or 1
    load = [float(x) for x in Path("/proc/loadavg").read_text().split()[:3]]
    mem = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, v = line.split(":", 1)
        mem[k] = int(v.strip().split()[0]) // 1024
    psi = {}
    for res in ("cpu", "memory", "io"):
        try:
            for line in Path(f"/proc/pressure/{res}").read_text().splitlines():
                if line.startswith("some"):
                    psi[res] = float(line.split("avg60=")[1].split()[0])
        except OSError:
            pass
    marc_procs, kasm, ollama = proc_scan()
    marc_cpu = marc_cpu_pct(marc_procs, now)
    mem_avail = mem.get("MemAvailable", 0)
    gpu = gpu_name()
    # marc "present" = bureau Kasm ouvert; "busy" = il tape/regarde vraiment
    # quelque chose, ou l'agent tourne fort pour lui.
    busy = marc_cpu > BUSY_CPU_PCT or (kasm and marc_cpu > 5.0)
    # `tty` prouve en plus que marc EST devant tower (shell recent) : c'est le
    # signal d'usage reel que les fenetres d'absence respectent. 'connecte' :
    # interaction recente par n'importe quel canal (shell, session hermes
    # interactive, web UI), la porte reactive historique.
    tty_why = marc_tty_active()
    connected_why = tty_why or hermes_interactive_active() or webui_active() or ""
    connected = bool(connected_why)
    if busy or tty_why:
        _calm["last_busy"] = now
    calm = None if _calm["last_busy"] is None else max(0.0, now - _calm["last_busy"])
    verdict = presence.verdict(PRESENCE_CFG, read_overrides(),
                               presence.now_local(PRESENCE_CFG),
                               busy, tty_why, connected, connected_why)
    return {
        "at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "threads": threads,
        "load1": round(load[0], 2), "load5": round(load[1], 2), "load15": round(load[2], 2),
        "mem_total_mb": mem.get("MemTotal", 0), "mem_avail_mb": mem_avail,
        "swap_used_mb": mem.get("SwapTotal", 0) - mem.get("SwapFree", 0),
        "psi_cpu": psi.get("cpu"), "psi_io": psi.get("io"),
        "marc_cpu_pct": round(marc_cpu, 1),
        "marc_present": kasm, "marc_busy": busy,
        "marc_connected": connected, "marc_connected_why": connected_why,
        "marc_calm_seconds": int(calm) if calm is not None else None,
        "presence": verdict["state"], "presence_why": verdict["why"],
        "presence_window": verdict["window"], "presence_until": verdict["until"],
        "presence_absent_confident": verdict["absent_confident"],
        "local_model_running": ollama,
        "gpu": gpu,
    }


# ---------------------------------------------------------------------- policy

def budget(m: dict) -> dict:
    """Budget LLM payant du jour (UTC, comme la fenetre gratuite d'OpenRouter)."""
    day = dt.datetime.now(dt.timezone.utc).date().isoformat()
    spent = one("select value from state where key = 'paid_spent_today'") or {}
    cap = one("select value from state where key = 'paid_budget_cents_per_day'")
    if spent.get("day") != day:
        spent = {"day": day, "cents": 0}
        exec_(f"update state set value = {q(json.dumps(spent))}::jsonb, updated_at = now() "
              "where key = 'paid_spent_today'")
    left = int(cap or 0) - int(spent.get("cents") or 0)
    return {"day": day, "cap_cents": int(cap or 0), "spent_cents": int(spent.get("cents") or 0),
            "left_cents": left}


def refuse(task: dict, m: dict, b: dict) -> str | None:
    """Raison de ne pas demarrer maintenant, ou None si c'est bon."""
    ceiling = LOAD_CEILING[task["cpu_class"]] * m["threads"]
    heavy_running = int(one("select count(*) from tasks where status='running' and cpu_class='heavy'") or 0)
    need = task["mem_min_mb"] + RESERVE_MB
    forced = False
    if task["deadline"]:
        deadline = dt.datetime.fromisoformat(task["deadline"])
        eta = dt.timedelta(minutes=int(task["est_minutes"] or 30))
        if dt.datetime.now(dt.timezone.utc) + eta >= deadline:
            forced = True  # il faut demarrer pour tenir l'echeance
    if task["requires_gpu"] and not m["gpu"]:
        return "aucun GPU utilisable sur cette machine"
    # `needs_absence` : la porte la plus stricte, et meme une echeance ne la
    # franchit pas (tache de fond pure). L'absence est devinee (presence.py) :
    # fenetre sommeil/travail + machine au repos, ou inactivite reactive.
    if task.get("needs_absence"):
        ok, why = presence.may_start(
            m.get("presence"), bool(m.get("presence_absent_confident")),
            bool(m.get("marc_connected")), m.get("marc_calm_seconds"),
            WINDOW_CALM_SECONDS)
        if not ok:
            return f"attend une absence de marc ({why})"
    if m["mem_avail_mb"] < need:
        return f"RAM libre {m['mem_avail_mb']} Mo < {task['mem_min_mb']}+{RESERVE_MB} requis"
    if forced:
        return None if m["mem_avail_mb"] >= need else "echeance mais RAM insuffisante"
    if m["paused"] and task["priority"] > 50:
        return "file en pause"
    if m["marc_busy"] and not task["while_busy"] and task["priority"] > 50:
        return f"marc travaille (cpu marc {m['marc_cpu_pct']}%, load {m['load1']})"
    if task["cpu_class"] == "heavy" and (m["load1"] > ceiling or heavy_running >= 1):
        return f"load {m['load1']} > {ceiling:.1f} (ou une tache lourde deja en cours)"
    if task["cpu_class"] == "medium" and m["load1"] > ceiling:
        return f"load {m['load1']} > {ceiling:.1f}"
    if task["cpu_class"] == "light" and m["load1"] > ceiling:
        return f"load {m['load1']} > {ceiling:.1f}"
    if task["llm_cost"] == "paid":
        if b["left_cents"] <= 0:
            return f"budget payant epuise ({b['spent_cents']}/{b['cap_cents']} centimes)"
        if m["local_model_running"] and m["gpu"]:
            return None  # un modele local tourne: tokens payants inutiles
    return None


# ------------------------------------------------------------------- execution

def start(task: dict, m: dict, b: dict, dry: bool) -> bool:
    """Lance la tache; False si le demarrage a echoue (la ligne est deja mise a jour)."""
    tid = task["id"]
    unit = f"taskq-{tid}"
    if not dry:
        try:
            if task["kind"] == "systemd_unit":
                subprocess.run(["systemctl", "start", task["target"]], check=True, timeout=60)
                unit = task["target"]
            else:
                # Root -> unite systeme; sinon unite du gestionnaire utilisateur
                # (meme effet, pas de polkit a demander).
                cmd = ["systemd-run", "--collect", "--quiet", "--unit", unit]
                if os.geteuid() != 0:
                    cmd.append("--user")
                cmd += ["--property", "Type=exec", "--property", "TimeoutStartSec=infinity"]
                # Les taches de la file sont des charges de fond : poids CPU/IO
                # bas (background.slice, voir services/cpu-priority). Elles
                # remplissent le CPU libre mais cedent le pas a l'interactif.
                # Sans Slice explicite, systemd-run les pose dans system.slice
                # au poids par defaut (100), a egalite avec le gateway hermes.
                if os.geteuid() == 0:
                    cmd += ["--property", "Slice=background.slice"]
                if os.geteuid() == 0:
                    cmd += ["--property", f"User={task['run_as']}"]
                if task["workdir"]:
                    cmd += ["--property", f"WorkingDirectory={task['workdir']}"]
                for k, v in (task["env"] or {}).items():
                    cmd.append(f"--setenv={k}={v}")
                cmd += ["/bin/sh", "-lc", task["target"]]
                subprocess.run(cmd, check=True, timeout=120)
        except subprocess.SubprocessError as e:
            decision(tid, "fail", f"demarrage impossible: {e}", m)
            exec_(f"update tasks set status='failed', note={q(f'demarrage impossible: {e}')}, "
                  f"finished_at=now(), updated_at=now() where id={tid}")
            return False
    else:
        # Mode rapport : annonce seulement, aucune ecriture (ni base ni systemd).
        return True
    exec_(
        "update tasks set status='running', unit=" + q(unit) + ", started_at=now(), "
        f"updated_at=now(), attempts=attempts+1 where id={tid}"
    )
    if task["llm_cost"] == "paid" and task["paid_cap_cents"]:
        b["spent_cents"] += int(task["paid_cap_cents"])
        exec_(f"update state set value = {q(json.dumps({'day': b['day'], 'cents': b['spent_cents']}))}::jsonb, "
              "updated_at=now() where key='paid_spent_today'")
    decision(tid, "start", start_reason(task, m), m)
    return True


def start_reason(task: dict, m: dict) -> str:
    bits = [f"{task['cpu_class']}", f"load {m['load1']}/{m['threads']} thr",
            f"ram libre {m['mem_avail_mb']} Mo"]
    if not m["marc_busy"]:
        bits.append("marc inactif" if not m["marc_present"] else "marc present mais calme")
    if task.get("needs_absence"):
        bits.append(f"marc absent ({m.get('presence')}, tache de fond)")
    if task["deadline"]:
        bits.append("echeance proche")
    if task["llm_cost"] != "none":
        bits.append(f"tokens {task['llm_cost']}")
    return ", ".join(bits)


def poll_running(m: dict, dry: bool) -> None:
    for t in (one("select coalesce(json_agg(row_to_json(x)), '[]') from ("
                  "select id, unit, target, kind, attempts, max_attempts, key,"
                  "       round(extract(epoch from (now() - started_at)) / 60) as minutes "
                  "from tasks where status='running' and assigned_host is null) x") or []):
        unit = t["unit"] or t["target"]
        info = {}
        try:
            out = subprocess.run(
                ["systemctl", "show", unit, "-p", "ActiveState", "-p", "SubState", "-p", "ExecMainStatus"],
                capture_output=True, text=True, timeout=30,
            )
            info = dict(line.split("=", 1) for line in out.stdout.strip().splitlines() if "=" in line)
        except subprocess.SubprocessError:
            pass
        state, sub = info.get("ActiveState", ""), info.get("SubState", "")
        if state == "failed" or (state in ("inactive", "dead") and sub in ("dead", "exited", "failed")):
            code = int(info.get("ExecMainStatus") or 0)
            ok = state != "failed" and code == 0
            note = f"termine en {int(t['minutes'] or 0)} min"
            if ok:
                exec_(f"update tasks set status='done', exit_code={code}, finished_at=now(), "
                      f"updated_at=now(), note={q(note)} where id={t['id']}")
                decision(t["id"], "finish", f"{t['target']} {note}", m)
            elif t["attempts"] < t["max_attempts"]:
                exec_(f"update tasks set status='queued', exit_code={code}, note={q('echec, nouvelle tentative')}, "
                      f"not_before=now() + interval '5 minutes', updated_at=now() where id={t['id']}")
                decision(t["id"], "fail", f"{t['target']} a echoue (code {code}), nouvel essai", m)
            else:
                exec_(f"update tasks set status='failed', exit_code={code}, finished_at=now(), "
                      f"updated_at=now() where id={t['id']}")
                decision(t["id"], "fail", f"{t['target']} a echoue definitivement (code {code})", m)


# ------------------------------------------------------------------------ pass

def stop_absent_running(m: dict, dry: bool) -> list[int]:
    """Interrompt les taches `needs_absence` en cours des que marc revient.

    Pendant une fenetre d'absence confirmee, seul l'usage reel de la machine
    coupe le job (un message depuis le telephone au bureau ne compte pas) ;
    hors fenetre, la premiere interaction le coupe. La tache repart toute
    seule a sa prochaine absence : elle est remise en file (pas comptee comme
    un echec, attempts intouche).
    """
    stop, why = presence.must_stop(
        m.get("presence"), bool(m.get("presence_absent_confident")),
        bool(m.get("marc_connected")))
    if not stop:
        return []
    running = one(
        "select coalesce(json_agg(row_to_json(x)), '[]') from ("
        "select id, unit, target from tasks where status='running' and needs_absence"
        " and assigned_host is null) x"
    ) or []
    stopped = []
    for t in running:
        unit = t["unit"] or t["target"]
        if not dry:
            try:
                # systemctl stop est bloquant : au retour, l'unite est arretee.
                subprocess.run(["systemctl", "stop", unit], capture_output=True, timeout=180)
            except subprocess.SubprocessError as e:
                log(f"arret impossible de {unit}: {e!r}")
            exec_(f"update tasks set status='queued', exit_code=null, note="
                  f"{q('interrompu: marc est revenu')}, not_before=now(), updated_at=now() "
                  f"where id={t['id']}")
            decision(t["id"], "pause",
                     f"marc est revenu ({why}): tache de fond interrompue, "
                     "reprise a la prochaine absence", m)
        stopped.append(t["id"])
    return stopped


def pass_once(dry: bool = False) -> dict:
    m = read_metrics()
    m["paused"] = json.loads(one("select value from state where key='paused'") or "false")
    b = budget(m)
    if not dry:
        exec_(f"insert into state (key, value, updated_at) values ('last_metrics', "
              f"{q(json.dumps({**m, 'budget': b}))}::jsonb, now()) "
              "on conflict (key) do update set value = excluded.value, updated_at = now()")
    stopped_absent = stop_absent_running(m, dry)
    poll_running(m, dry)

    started, deferred = [], []
    seen: set = set()  # taches deja examinees dans CETTE passe : sans ca, une
    # tache qui reste `queued` (report, ou dry-run qui n'ecrit rien) serait
    # rejouee a chaque tour de la boucle, a l'infini.
    while True:
        tasks = one(
            "select coalesce(json_agg(row_to_json(x)), '[]') from ("
            "  select id, key, kind, target, run_as, workdir, env, cpu_class, mem_min_mb, gpu,"
            "         llm_cost, est_minutes, paid_cap_cents, priority, while_busy, needs_absence, requires_gpu,"
            "         deadline::text, attempts, max_attempts"
            # `requires` non vide = tache de flotte : elle appartient aux workers
            # distants (/worker/beat la remet a un hote), pas au dispatcher local.
            "  from tasks where status='queued' and not_before <= now()"
            "   and requires = '{}'::text[]"
            "  order by priority, not_before limit 20) x"
        ) or []
        if not tasks:
            break
        progressed = False
        for t in tasks:
            if t["id"] in seen:
                continue
            seen.add(t["id"])
            if t["requires_gpu"] and not m["gpu"]:
                if not dry:
                    exec_(f"update tasks set status='blocked', note='GPU requis, absent', updated_at=now() where id={t['id']}")
                    decision(t["id"], "block", "GPU requis mais aucun GPU sur tower", m)
                progressed = True
                continue
            why = refuse(t, m, b)
            if why:
                deferred.append((t["id"], why))
                # on n'ecrit une decision de report qu'une fois par heure et par tache
                if not dry:
                    exec_(
                        "insert into decisions (task_id, action, reason, metrics) "
                        f"select {t['id']}, 'defer', {q(why)}, {q(json.dumps({'load1': m['load1'], 'marc_busy': m['marc_busy']}))}::jsonb "
                        "where not exists (select 1 from decisions d where d.task_id = "
                        f"{t['id']} and d.action='defer' and d.reason = {q(why[:500])} and d.at > now() - interval '1 hour')"
                    )
                continue
            if start(t, m, b, dry):
                started.append(t["id"])
            progressed = True
            if len(started) >= 2:  # pas plus de deux demarrages par tour
                break
        if not progressed:
            break

    report = {"metrics": m, "budget": b, "started": started, "deferred": deferred,
              "stopped_absent": stopped_absent}
    state = one("select value from state where key='last_metrics'") or {}
    if started:
        log(f"demarre {started}; reporte {[d[0] for d in deferred]}")
    return report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not Path("/run/systemd/system").exists():
        log("pas de systemd, mode simulation")
        args.dry_run = True

    if args.once:
        print(json.dumps(pass_once(args.dry_run), indent=2, default=str))
        return 0

    log(f"taskq dispatcher demarre (poll {POLL_SECONDS}s, reserve {RESERVE_MB} Mo, "
        f"busy>{BUSY_CPU_PCT}% marc)")
    while True:
        try:
            pass_once(args.dry_run)
        except Exception as e:  # une erreur ne doit jamais tuer la boucle
            log(f"erreur de tour: {e!r}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
