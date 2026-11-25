#!/usr/bin/env python3
"""taskq dispatcher.

24/7 scheduler for tower. It owns one question: *may this task run right now,
and if not, when?* It watches the machine (load, RAM, GPU, whether marc is
using the box -- cpu, tty, Hermes activity, plus the sleep/work windows
of presence.py), the queue, and the money (paid LLM budget), then starts tasks
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

import presence  # same folder as this script (copied by the Nix module)

DB = os.environ.get("TASKQ_DATABASE_URL", "postgresql://taskq@127.0.0.1/taskq")
WINNIE_DB = os.environ.get("TASKQ_WINNIE_DATABASE_URL", "")
POLL_SECONDS = int(os.environ.get("TASKQ_POLL_SECONDS", "20"))
MARC_UID = int(os.environ.get("TASKQ_MARC_UID") or "1000")  # empty -> 1000
RESERVE_MB = int(os.environ.get("TASKQ_RESERVE_MB", "4096"))
BUSY_CPU_PCT = float(os.environ.get("TASKQ_BUSY_CPU_PCT", "25"))
# Inactivity window (minutes) for `needs_absence`: no interaction from
# marc (ssh/local shell, interactive Hermes session, web UI) for this delay
# => background tasks may start; his first interaction cuts them.
# To this are added the predictive absence windows (sleep / work,
# presence.py) and a calm hysteresis for restart within a window.
ABSENCE_MINUTES = int(os.environ.get("TASKQ_ABSENCE_MINUTES", "15"))
WINDOW_CALM_SECONDS = int(os.environ.get("TASKQ_WINDOW_CALM_SECONDS", "90"))
HERMES_STATE_DB = os.environ.get("TASKQ_HERMES_STATE_DB", "/var/lib/hermes/.hermes/state.db")
PRESENCE_CFG = presence.load_config()
# Last moment when marc really touched the machine (cpu or tty), None at
# startup: used to require WINDOW_CALM_SECONDS of calm before restarting a
# background task within an absence window (a phone at the
# office does not count, only tower usage counts).
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
    """SQL literal for a string (escapes the quotes)."""
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
    """CPU % (one unit = one core) consumed by marc's processes since the
    last sample."""
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
    """Returns (marc's jiffies, kasm active, ollama active, name of a usable GPU)."""
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
        if owner in (MARC_UID, 0):  # Xvnc runs as marc, ollama as ollama
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
    """A recently used marc shell (ssh from the Mac, local tty)."""
    try:
        out = subprocess.run(["who", "-u"], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return "who unavailable (assumed connected)"
    for line in out.splitlines():
        f = line.split()
        if len(f) < 5 or f[0] != "marc":
            continue
        idle = f[4]
        if idle == ".":
            return "marc shell active right now"
        if ":" in idle:
            try:
                h, m = idle.split(":")[:2]
                if int(h) * 60 + int(m) < ABSENCE_MINUTES:
                    return f"marc shell used {idle} ago"
            except ValueError:
                continue
    return None


def hermes_interactive_active() -> str | None:
    """A recent interactive Hermes session (desktop app, CLI, matrix).

    Autonomous sources (cron, oneshot, subagent) do not count: they
    run without marc. Two independent reads (sessions + messages
    joined to interactive sources): a WAL reader that would only see a
    stale state cannot zero both at the same time (observed: a
    `sqlite3 -readonly` returned 0 while 552 messages were being written).
    Any read error => 'connected': we never start a background task
    when in doubt.
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
        return f"hermes state unreadable ({e}) (assumed connected)"
    if max(hits) > 0:
        return f"recent hermes activity < {ABSENCE_MINUTES} min (sessions {hits[0]}, messages {hits[1]})"
    return None


def webui_active() -> str | None:
    """A recent POST on the Hermes web UI: an action by marc.

    The probe's GET /login (every 30 s) does not count.
    """
    try:
        out = subprocess.run(
            ["journalctl", "-u", "hermes-webui", f"--since=-{ABSENCE_MINUTES} min",
             "-o", "cat", "--no-pager"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return "recent POST request on hermes-webui" if '"method": "POST"' in out else None


def read_overrides() -> dict:
    """Per-date overrides of the presence config (state table)."""
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
    # marc "present" = Kasm desktop open; "busy" = he is really typing/watching
    # something, or the agent is running hard for him.
    busy = marc_cpu > BUSY_CPU_PCT or (kasm and marc_cpu > 5.0)
    # `tty` additionally proves that marc IS in front of tower (recent shell): it is the
    # real-usage signal that the absence windows respect. 'connected':
    # recent interaction through any channel (shell, interactive hermes
    # session, web UI), the historical reactive gate.
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
    """Paid LLM budget of the day (UTC, like OpenRouter's free window)."""
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
    """Reason not to start now, or None if it is fine."""
    ceiling = LOAD_CEILING[task["cpu_class"]] * m["threads"]
    heavy_running = int(one("select count(*) from tasks where status='running' and cpu_class='heavy'") or 0)
    need = task["mem_min_mb"] + RESERVE_MB
    forced = False
    if task["deadline"]:
        deadline = dt.datetime.fromisoformat(task["deadline"])
        eta = dt.timedelta(minutes=int(task["est_minutes"] or 30))
        if dt.datetime.now(dt.timezone.utc) + eta >= deadline:
            forced = True  # must start to meet the deadline
    if task["requires_gpu"] and not m["gpu"]:
        return "no usable GPU on this machine"
    # `needs_absence`: the strictest gate, and even a deadline does not
    # cross it (pure background task). The absence is inferred (presence.py):
    # sleep/work window + machine at rest, or reactive inactivity.
    if task.get("needs_absence"):
        ok, why = presence.may_start(
            m.get("presence"), bool(m.get("presence_absent_confident")),
            bool(m.get("marc_connected")), m.get("marc_calm_seconds"),
            WINDOW_CALM_SECONDS)
        if not ok:
            return f"waiting for an absence of marc ({why})"
    if m["mem_avail_mb"] < need:
        return f"free RAM {m['mem_avail_mb']} MB < {task['mem_min_mb']}+{RESERVE_MB} required"
    if forced:
        return None if m["mem_avail_mb"] >= need else "deadline but insufficient RAM"
    if m["paused"] and task["priority"] > 50:
        return "queue paused"
    if m["marc_busy"] and not task["while_busy"] and task["priority"] > 50:
        return f"marc is working (marc cpu {m['marc_cpu_pct']}%, load {m['load1']})"
    if task["cpu_class"] == "heavy" and (m["load1"] > ceiling or heavy_running >= 1):
        return f"load {m['load1']} > {ceiling:.1f} (or a heavy task already running)"
    if task["cpu_class"] == "medium" and m["load1"] > ceiling:
        return f"load {m['load1']} > {ceiling:.1f}"
    if task["cpu_class"] == "light" and m["load1"] > ceiling:
        return f"load {m['load1']} > {ceiling:.1f}"
    if task["llm_cost"] == "paid":
        if b["left_cents"] <= 0:
            return f"paid budget exhausted ({b['spent_cents']}/{b['cap_cents']} cents)"
        if m["local_model_running"] and m["gpu"]:
            return None  # a local model is running: paid tokens useless
    return None


# ------------------------------------------------------------------- execution

def start(task: dict, m: dict, b: dict, dry: bool) -> bool:
    """Starts the task; False if the start failed (the row is already updated)."""
    tid = task["id"]
    unit = f"taskq-{tid}"
    if not dry:
        try:
            if task["kind"] == "systemd_unit":
                subprocess.run(["systemctl", "start", task["target"]], check=True, timeout=60)
                unit = task["target"]
            else:
                # Root -> system unit; otherwise user manager unit
                # (same effect, no polkit to ask).
                cmd = ["systemd-run", "--collect", "--quiet", "--unit", unit]
                if os.geteuid() != 0:
                    cmd.append("--user")
                cmd += ["--property", "Type=exec", "--property", "TimeoutStartSec=infinity"]
                if os.geteuid() == 0:
                    cmd += ["--property", f"User={task['run_as']}"]
                if task["workdir"]:
                    cmd += ["--property", f"WorkingDirectory={task['workdir']}"]
                for k, v in (task["env"] or {}).items():
                    cmd.append(f"--setenv={k}={v}")
                cmd += ["/bin/sh", "-lc", task["target"]]
                subprocess.run(cmd, check=True, timeout=120)
        except subprocess.SubprocessError as e:
            decision(tid, "fail", f"start impossible: {e}", m)
            exec_(f"update tasks set status='failed', note={q(f'start impossible: {e}')}, "
                  f"finished_at=now(), updated_at=now() where id={tid}")
            return False
    else:
        # Report mode: announce only, no write (neither db nor systemd).
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
            f"free ram {m['mem_avail_mb']} MB"]
    if not m["marc_busy"]:
        bits.append("marc inactive" if not m["marc_present"] else "marc present but calm")
    if task.get("needs_absence"):
        bits.append(f"marc absent ({m.get('presence')}, background task)")
    if task["deadline"]:
        bits.append("deadline close")
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
            note = f"finished in {int(t['minutes'] or 0)} min"
            if ok:
                exec_(f"update tasks set status='done', exit_code={code}, finished_at=now(), "
                      f"updated_at=now(), note={q(note)} where id={t['id']}")
                decision(t["id"], "finish", f"{t['target']} {note}", m)
            elif t["attempts"] < t["max_attempts"]:
                exec_(f"update tasks set status='queued', exit_code={code}, note={q('failure, new attempt')}, "
                      f"not_before=now() + interval '5 minutes', updated_at=now() where id={t['id']}")
                decision(t["id"], "fail", f"{t['target']} failed (code {code}), new attempt", m)
            else:
                exec_(f"update tasks set status='failed', exit_code={code}, finished_at=now(), "
                      f"updated_at=now() where id={t['id']}")
                decision(t["id"], "fail", f"{t['target']} failed permanently (code {code})", m)


# ------------------------------------------------------------------------ pass

def stop_absent_running(m: dict, dry: bool) -> list[int]:
    """Interrupts the running `needs_absence` tasks as soon as marc comes back.

    During a confirmed absence window, only real machine usage
    cuts the job (a message from the phone at the office does not count);
    outside a window, the first interaction cuts it. The task restarts on its
    own at its next absence: it is requeued (not counted as
    a failure, attempts untouched).
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
                # systemctl stop is blocking: on return, the unit is stopped.
                subprocess.run(["systemctl", "stop", unit], capture_output=True, timeout=180)
            except subprocess.SubprocessError as e:
                log(f"stop impossible for {unit}: {e!r}")
            exec_(f"update tasks set status='queued', exit_code=null, note="
                  f"{q('interrupted: marc came back')}, not_before=now(), updated_at=now() "
                  f"where id={t['id']}")
            decision(t["id"], "pause",
                     f"marc came back ({why}): background task interrupted, "
                     "resumed at the next absence", m)
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
    seen: set = set()  # tasks already examined in THIS pass: without that, a
    # task that stays `queued` (deferral, or dry-run that writes nothing) would be
    # replayed on every loop turn, forever.
    while True:
        tasks = one(
            "select coalesce(json_agg(row_to_json(x)), '[]') from ("
            "  select id, key, kind, target, run_as, workdir, env, cpu_class, mem_min_mb, gpu,"
            "         llm_cost, est_minutes, paid_cap_cents, priority, while_busy, needs_absence, requires_gpu,"
            "         deadline::text, attempts, max_attempts"
            # non-empty `requires` = fleet task: it belongs to the remote
            # workers (/worker/beat assigns it to a host), not to the local dispatcher.
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
                    exec_(f"update tasks set status='blocked', note='GPU required, absent', updated_at=now() where id={t['id']}")
                    decision(t["id"], "block", "GPU required but no GPU on tower", m)
                progressed = True
                continue
            why = refuse(t, m, b)
            if why:
                deferred.append((t["id"], why))
                # a deferral decision is written only once per hour and per task
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
            if len(started) >= 2:  # no more than two starts per turn
                break
        if not progressed:
            break

    report = {"metrics": m, "budget": b, "started": started, "deferred": deferred,
              "stopped_absent": stopped_absent}
    state = one("select value from state where key='last_metrics'") or {}
    if started:
        log(f"started {started}; deferred {[d[0] for d in deferred]}")
    return report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not Path("/run/systemd/system").exists():
        log("no systemd, simulation mode")
        args.dry_run = True

    if args.once:
        print(json.dumps(pass_once(args.dry_run), indent=2, default=str))
        return 0

    log(f"taskq dispatcher started (poll {POLL_SECONDS}s, reserve {RESERVE_MB} MB, "
        f"busy>{BUSY_CPU_PCT}% marc)")
    while True:
        try:
            pass_once(args.dry_run)
        except Exception as e:  # an error must never kill the loop
            log(f"turn error: {e!r}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
