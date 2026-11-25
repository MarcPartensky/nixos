#!/usr/bin/env python3
"""taskq-worker: fleet agent (deck, laptop, anywhere, mac).

PULL model: the worker opens no port and does not need to be reachable by
anyone. It calls the master (taskq-api, route /worker/*) every
TASKQ_WORKER_BEAT seconds; each call serves as a heartbeat (it
renews the lease of the running tasks) AND as a request for work.

Consequence of an outage (deck asleep, wifi drops, reboot): the worker
stops beating, the master sees the lease expire and requeues the task. The
worker has NO local state: nothing to reconcile on return, it beats again and picks up
what the master gives it back.

Semantics: at least once. A task resumed after an outage may have already
produced its effects; that is why fleet tasks carry an idempotency `key`
and why the targets must be idempotent (systemd unit,
replayable command).

Env:
  TASKQ_MASTER_URL        http://100.64.0.3:9078 (required)
  TASKQ_WORKER_NAME       deck | laptop | anywhere | mac (required)
  TASKQ_WORKER_TOKEN_FILE /run/keys/taskq-worker-token (required)
  TASKQ_WORKER_BEAT       15 (seconds)
  TASKQ_WORKER_SLOTS      1 (simultaneous tasks)
  TASKQ_WORKER_MAX_LOAD   0 = never refuse; otherwise no new task
                          above this load (deck that is playing)
  TASKQ_WORKER_ALLOW_UNITS  comma-separated list, strict allowlist
  TASKQ_WORKER_ALLOW_COMMANDS 1 to allow kind=command (shell)
  TASKQ_WORKER_CAPS       comma-separated list (e.g. nix,render,heavy)
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

MASTER = (os.environ.get("TASKQ_MASTER_URL") or "").rstrip("/")
NAME = os.environ.get("TASKQ_WORKER_NAME") or ""
TOKEN_FILE = os.environ.get("TASKQ_WORKER_TOKEN_FILE") or ""
BEAT = float(os.environ.get("TASKQ_WORKER_BEAT") or 15)
SLOTS = int(os.environ.get("TASKQ_WORKER_SLOTS") or 1)
MAX_LOAD = float(os.environ.get("TASKQ_WORKER_MAX_LOAD") or 0)
CAPS = [c.strip() for c in (os.environ.get("TASKQ_WORKER_CAPS") or "").split(",") if c.strip()]
UNITS = [u.strip() for u in (os.environ.get("TASKQ_WORKER_ALLOW_UNITS") or "").split(",") if u.strip()]
ALLOW_COMMANDS = (os.environ.get("TASKQ_WORKER_ALLOW_COMMANDS") or "0") == "1"

RUNNING: dict[int, dict] = {}
LOCK = threading.Lock()
STOP = threading.Event()


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def token() -> str:
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def metrics() -> dict:
    try:
        load1 = os.getloadavg()[0]
    except OSError:
        load1 = 0.0
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k] = int(v.split()[0])
    except OSError:
        pass
    live = threading.active_count()
    return {
        "load1": round(load1, 2),
        "threads": os.cpu_count(),
        "mem_avail_mb": round(mem.get("MemAvailable", 0) / 1024),
        "slots": SLOTS,
        "running": len(RUNNING),
        "threads_agent": live,
        "host": socket.gethostname(),
    }


def call(path: str, payload: dict, timeout: float = 30) -> dict:
    req = urllib.request.Request(
        f"{MASTER}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token()}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def should_accept() -> bool:
    if MAX_LOAD <= 0:
        return True
    try:
        return os.getloadavg()[0] <= MAX_LOAD
    except OSError:
        return True


# ------------------------------------------------------------------ execution

def run_command(task: dict, handle: dict) -> tuple[int, str]:
    env = dict(os.environ)
    env.update({str(k): str(v) for k, v in (task.get("env") or {}).items()})
    cmd = ["/bin/sh", "-lc", task["target"]]
    run_as = task.get("run_as") or ""
    if os.geteuid() == 0 and run_as and run_as != "root":
        cmd = ["setpriv", f"--reuid={run_as}", f"--regid={run_as}", "--clear-groups"] + cmd
    p = subprocess.Popen(cmd, cwd=task.get("workdir") or None, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="replace", start_new_session=True)
    handle["proc"] = p
    out, _ = p.communicate()
    return p.returncode, (out or "")[-4000:]


def run_unit(task: dict, handle: dict) -> tuple[int, str]:
    unit = task["target"]
    if unit not in UNITS:
        return 126, f"unit {unit} outside the local allowlist ({', '.join(UNITS) or 'empty'})"
    subprocess.run(["systemctl", "start", unit], check=False, timeout=120)
    handle["unit"] = unit
    # Wait for the real end: start does not block when the service forks.
    while not STOP.is_set():
        out = subprocess.run(
            ["systemctl", "show", unit, "-p", "ActiveState", "-p", "Result",
             "-p", "ExecMainStatus"],
            capture_output=True, text=True, timeout=30,
        ).stdout
        info = dict(line.split("=", 1) for line in out.strip().splitlines() if "=" in line)
        state = info.get("ActiveState", "")
        if state in ("inactive", "failed", "dead"):
            code = int(info.get("ExecMainStatus") or 0)
            ok = state != "failed" and info.get("Result", "success") == "success"
            return (0 if ok else (code or 1)), f"{unit}: {state}/{info.get('Result')}"
        time.sleep(5)
    return 130, f"{unit}: interrupted"


def execute(task: dict) -> None:
    tid = int(task["id"])
    handle: dict = {}
    with LOCK:
        RUNNING[tid] = handle
    code, note = 1, "worker: no execution"
    try:
        if task["kind"] == "systemd_unit":
            code, note = run_unit(task, handle)
        elif task["kind"] == "command" and ALLOW_COMMANDS:
            code, note = run_command(task, handle)
        else:
            code, note = 126, f"kind {task['kind']} refused by this worker"
    except Exception as e:  # a failure must never kill the worker
        code, note = 1, f"worker: {e!r}"[:500]
    status = "done" if code == 0 else "failed"
    for attempt in range(6):
        try:
            call("/worker/report", {"name": NAME, "id": tid, "status": status,
                                    "exit_code": code, "note": note})
            log(f"#{tid} {status} ({code}) {note[:120]}")
            break
        except Exception as e:
            log(f"report #{tid} failed ({attempt + 1}/6): {e!r}")
            time.sleep(min(60, 5 * (attempt + 1)))
    with LOCK:
        RUNNING.pop(tid, None)


def abort(tid: int) -> None:
    with LOCK:
        handle = RUNNING.get(tid)
    if not handle:
        return
    log(f"#{tid} cancelled on master's order")
    proc = handle.get("proc")
    if proc and proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
    unit = handle.get("unit")
    if unit:
        subprocess.run(["systemctl", "stop", unit], check=False, timeout=60)


# ----------------------------------------------------------------------- loop

def beat_once() -> None:
    with LOCK:
        running = [{"id": tid, "at": int(h.get("since") or time.time())}
                   for tid, h in RUNNING.items()]
        free = max(0, SLOTS - len(RUNNING))
    payload = {
        "name": NAME,
        "caps": CAPS,
        "metrics": metrics(),
        "running": [r["id"] for r in running],
        "accept": should_accept() and free > 0,
        "free_slots": free,
    }
    ans = call("/worker/beat", payload)
    for tid in ans.get("abort") or []:
        abort(int(tid))
    for task in ans.get("claim") or []:
        if not should_accept():
            break
        with LOCK:
            if len(RUNNING) >= SLOTS:
                break
        log(f"#{task['id']} received ({task['cpu_class']}) {task['target'][:90]}")
        threading.Thread(target=execute, args=(task,), daemon=True).start()


def main() -> None:
    if not (MASTER and NAME and TOKEN_FILE):
        print("TASKQ_MASTER_URL, TASKQ_WORKER_NAME and TASKQ_WORKER_TOKEN_FILE are required",
              file=sys.stderr)
        return 2
    if not shutil.which("systemctl") and not ALLOW_COMMANDS:
        log("warning: neither systemctl nor commands are allowed, this worker cannot execute anything")
    log(f"worker {NAME} -> {MASTER} (slots {SLOTS}, caps {', '.join(CAPS) or '-'})")
    backoff = 5.0
    while not STOP.is_set():
        t0 = time.time()
        try:
            beat_once()
            backoff = 5.0
        except urllib.error.HTTPError as e:
            log(f"master refuses the beat: HTTP {e.code} {e.reason}")
            if e.code in (401, 403):
                time.sleep(BEAT)
                continue
        except Exception as e:
            log(f"master unreachable ({e!r}), retry in {int(backoff)} s")
            time.sleep(backoff)
            backoff = min(120.0, backoff * 2)
            continue
        STOP.wait(max(1.0, BEAT - (time.time() - t0)))
    log("clean shutdown")


if __name__ == "__main__":
    sys.exit(main() or 0)
