#!/usr/bin/env python3
"""CPU governor for winnie jobs (declaration: services/cpu-priority/default.nix).

Principle
--------
The declarative CPUQuota caps are the SAFE value (state "capped"). This
governor only WIDENS them (state "wide") when the CPU pressure of
user.slice (marc's sessions + Hermes sessions) stays near zero for
2 minutes: at that point nobody is queuing for CPU and the
batches can take the machine. Exception: the browser jobs (see
HARD_CAP below) stay capped at 30% of total CPU at all times.
As soon as an interactive task waits for
CPU (some avg10 >= HIGH), we close back onto the declarative caps.

Why user.slice PSI and not system PSI: verified on 25/10/2026,
a cgroup's CFS throttling shows up in ITS PSI (probe with 4 threads under
CPUQuota=100%: some avg10=23%, full avg10=23%) and therefore in the
global PSI. A capped batch would flag itself as "someone is waiting"
and the valves would never open. The winnie units are
system units (system.slice), marc's and Hermes' sessions are in
user.slice: that is the right thermometer.

The overrides are set with `systemctl set-property --runtime`: they live
in /run and disappear on reboot. The declarative config remains the
reference, and if this governor stops we stay bounded (state "capped").

Cost: a tick only reads two files (/proc-like) and calls
`systemctl` only for the units whose cap changes. Do NOT go back to
`systemctl list-units` here: the full enumeration of units cost 1.1 s
of CPU per tick (measured on 25/10/2026).

Usage: winnie-cpu-governor [--print] [--force wide|capped]
"""
import json
import os
import pathlib
import subprocess
import sys
import time

# unit -> (cap % in capped state, cap % in wide state)
UNITS = {
    "ollama.service": (600, 1200),
    "winnie-calories.service": (400, 1200),
}
# winnie browser jobs: HARD cap of 30% of total (480% of 16 threads),
# never widened (marc's request 25/10/2026). Reasserted on each tick to
# catch a stale --runtime override (e.g. 400% from the old governor).
HARD_CAP = {
    "winnie-gmaps-scrape.service": 480,
    "winnie-ingest-nightly.service": 480,
    "winnie-hours-refresh.service": 480,
}
JOB_UNITS = (400, 1200)  # transient winnie-job-* units found at runtime

PRESSURE = pathlib.Path("/sys/fs/cgroup/user.slice/cpu.pressure")
# Forecast from the presence service (Rust, services/presence): `reserve` = marc
# will probably need the machine within 30 min (hourly habit or
# detected return home). In that case we do NOT loosen: we stay at the
# declarative caps, so the machine is already free when he arrives.
FORECAST = pathlib.Path("/var/lib/hermes/presence-dashboard/forecast.json")
FORECAST_MAX_AGE = 600  # s: beyond that, the forecast is stale, we ignore it
SYSTEM_SLICE = pathlib.Path("/sys/fs/cgroup/system.slice")
HIGH = 10.0      # some avg10 (%): interactive tasks are queuing
LOW = 2.0        # some avg10 (%): nobody is waiting
QUIET_TICKS = 8  # 8 ticks of 15 s = 2 min of calm before widening
STATE = pathlib.Path("/run/winnie-cpu-governor/state.json")


def pressure_some_avg10():
    """user.slice CPU pressure, or None if unreadable (we will stay bounded)."""
    try:
        for line in PRESSURE.read_text().splitlines():
            if line.startswith("some"):
                for token in line.split():
                    if token.startswith("avg10="):
                        return float(token.split("=", 1)[1])
    except OSError:
        return None
    return None


def reserve_now():
    """(reserve, reason) from forecast.json; (None, ...) if unavailable."""
    try:
        data = json.loads(FORECAST.read_text())
    except (OSError, ValueError):
        return None, "forecast unavailable"
    try:
        age = time.time() - float(data.get("at") or 0)
    except (TypeError, ValueError):
        return None, "forecast unreadable"
    if age > FORECAST_MAX_AGE:
        return None, f"stale forecast ({int(age)} s)"
    if data.get("reserve"):
        return True, str(data.get("why") or "reserve")
    return False, str(data.get("why") or "calm")


def transient_units():
    """Active winnie-job-* units, via the cgroup directory (no systemctl)."""
    try:
        names = os.listdir(SYSTEM_SLICE)
    except OSError:
        return []
    return [n for n in names if n.startswith("winnie-job-") and n.endswith(".service")]


def read_state():
    try:
        data = json.loads(STATE.read_text())
        return data.get("state", "capped"), int(data.get("quiet", 0)), data.get("applied", {})
    except (OSError, ValueError):
        return "capped", 0, {}


def main():
    argv = sys.argv[1:]
    dry = "--print" in argv
    force = argv[argv.index("--force") + 1] if "--force" in argv else None

    psi = pressure_some_avg10()
    state, quiet, applied = read_state()

    reserve, reserve_why = reserve_now()

    if force in ("wide", "capped"):
        new_state, new_quiet = force, 0
    elif reserve is True:
        # marc is arriving (or is here): keep the caps, without waiting for PSI
        new_state, new_quiet = "capped", 0
    elif psi is None:
        new_state, new_quiet = "capped", 0
    elif state == "wide":
        new_state, new_quiet = ("capped" if psi > HIGH else "wide"), 0
    else:
        new_quiet = quiet + 1 if psi < LOW else 0
        new_state = "wide" if new_quiet >= QUIET_TICKS else "capped"
        if new_state == "wide":
            new_quiet = 0

    shown = "unreadable" if psi is None else f"{psi:.2f}%"
    print(f"psi(user.slice) some avg10={shown} {state}({quiet}) -> {new_state}"
          f"  [reserve={reserve}: {reserve_why}]", flush=True)

    desired = {}
    for unit, (capped, wide) in UNITS.items():
        desired[unit] = wide if new_state == "wide" else capped
    for unit, quota in HARD_CAP.items():
        desired[unit] = quota
    for unit in transient_units():
        desired.setdefault(unit, JOB_UNITS[1] if new_state == "wide" else JOB_UNITS[0])

    if dry:
        for unit, quota in desired.items():
            print(f"  [dry-run] {unit}: {quota}%")
        return 0

    todo = {u: q for u, q in desired.items() if applied.get(u) != q or force is not None}
    for unit, quota in todo.items():
        subprocess.run(
            ["systemctl", "set-property", "--runtime", unit, f"CPUQuota={quota}%"],
            check=False, capture_output=True, timeout=15)
        applied[unit] = quota
    applied = {u: q for u, q in applied.items() if u in desired}

    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({"state": new_state, "quiet": new_quiet, "applied": applied}) + "\n")
    if todo:
        print(f"  applied: {', '.join(f'{u}={q}%' for u, q in todo.items())}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
