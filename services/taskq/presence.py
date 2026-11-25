"""marc's presence (work / sleep / machine) for the `needs_absence` gate.

The taskq dispatcher keeps a gate: a `needs_absence` task only runs
if marc is not using the machine. Historically the gate was REACTIVE
("no interaction for TASKQ_ABSENCE_MINUTES"). This module adds the
PREDICTIVE model marc asked for: declared sleep and work
windows (file /etc/taskq/presence.json, written by the Nix module), crossed
with the real signals (cpu of marc's processes, active tty, hermes or
webui activity), to guess his presence even when he is chatting from his phone at
the office (an interaction does not prove he is in front of tower).

Computed states:
  at_tower    machine used right now (marc cpu high or recent shell):
              a background task must pause
  away_work   work window (mon-fri) and machine idle: marc is at the
              office; his messages from another device do not count
  away_sleep  sleep window and no recent interaction: he is asleep
  nearby      outside a window, machine idle: the reactive rule (15 min with no
              interaction) decides

Per-date overrides (table `state`, key `presence_overrides`): kind "off"
(day off) or "wfh" (remote work) remove the work window for the day
concerned; sleep has no override in v1.

Tests (without touching the database):
  python3 presence.py --at '2026-10-26T10:30:00' --json
  python3 presence.py --at '2026-10-26T03:00:00' --busy
  TASKQ_PRESENCE_FAKE_NOW=... is also read by now_local(), which allows
  replaying a dry-run of the dispatcher at a simulated hour.
"""

from __future__ import annotations

import copy
import datetime as dt
import json
import os

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - python < 3.9
    ZoneInfo = None  # type: ignore

DEFAULT_CONFIG = {
    "tz": "America/New_York",
    "sleep": {"start": "02:30", "end": "08:30"},
    "work": {"days": [1, 2, 3, 4, 5], "start": "09:00", "end": "18:30"},
}
CONFIG_PATH = os.environ.get("TASKQ_PRESENCE_CONFIG", "/etc/taskq/presence.json")
OVERRIDE_KINDS = ("off", "wfh")
DAY_NAMES = ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"]


def load_config(path: str | None = None) -> dict:
    """Declarative config; falls back to DEFAULT_CONFIG if the file is missing.

    A partial file is merged over the defaults key by key: the Nix module
    can write only what it wants to override.
    """
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    try:
        with open(path or CONFIG_PATH, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return cfg
    if isinstance(raw, dict):
        if isinstance(raw.get("tz"), str):
            cfg["tz"] = raw["tz"]
        for key in ("sleep", "work"):
            if isinstance(raw.get(key), dict):
                cfg[key].update(raw[key])
    return cfg


def tz_of(cfg: dict) -> dt.tzinfo:
    if ZoneInfo is None:  # pragma: no cover
        return dt.timezone.utc
    try:
        return ZoneInfo(cfg.get("tz") or DEFAULT_CONFIG["tz"])
    except Exception:
        return ZoneInfo(DEFAULT_CONFIG["tz"])


def now_local(cfg: dict) -> dt.datetime:
    """Now in the config timezone.

    TASKQ_PRESENCE_FAKE_NOW (ISO) forces the instant: tests only, to
    replay a dry-run of the dispatcher at a simulated hour.
    """
    tz = tz_of(cfg)
    fake = os.environ.get("TASKQ_PRESENCE_FAKE_NOW")
    if fake:
        try:
            parsed = dt.datetime.fromisoformat(fake)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=tz)
            return parsed.astimezone(tz)
        except ValueError:
            pass
    return dt.datetime.now(tz)


def _hhmm(value: str) -> dt.time:
    h, m = str(value).split(":")[:2]
    return dt.time(int(h), int(m))


def windows_on(cfg: dict, overrides: dict, day: dt.date) -> list[tuple]:
    """Windows (kind, start, end) that START that day.

    Sleep is daily; work respects `days` (1 = Monday) and a
    date marked "off" or "wfh" has no work window.
    """
    tz = tz_of(cfg)
    out: list[tuple] = []
    sleep = cfg["sleep"]
    out.append(("sleep",
                dt.datetime.combine(day, _hhmm(sleep["start"]), tz),
                dt.datetime.combine(day, _hhmm(sleep["end"]), tz)))
    work = cfg["work"]
    kind_override = (overrides.get(day.isoformat()) or {}).get("kind")
    days = {int(d) for d in work.get("days", [])}
    if day.isoweekday() in days and kind_override not in OVERRIDE_KINDS:
        out.append(("work",
                    dt.datetime.combine(day, _hhmm(work["start"]), tz),
                    dt.datetime.combine(day, _hhmm(work["end"]), tz)))
    return out


def window_at(cfg: dict, overrides: dict, now: dt.datetime) -> tuple:
    """(kind, end) of the window active at `now`, or (None, None).

    We also look at the previous day: a window started yesterday can run
    into today.
    """
    for back in (1, 0):
        day = (now + dt.timedelta(days=back)).date()
        for kind, start, end in windows_on(cfg, overrides, day):
            if start <= now < end:
                return kind, end
    return None, None


def verdict(cfg: dict, overrides: dict, now: dt.datetime,
            busy: bool, tty_why: str | None,
            connected: bool, connected_why: str) -> dict:
    """The presence state at `now`, crossed with the real signals.

    busy/tty_why = tower USAGE signals (marc cpu, active shell);
    connected = recent interaction through any channel (the
    cautious part: read error => connected).
    """
    kind, until = window_at(cfg, overrides, now)
    until_iso = until.isoformat() if until else None
    if busy or tty_why:
        return {"state": "at_tower",
                "why": tty_why or "marc cpu high",
                "window": kind, "until": until_iso, "absent_confident": False}
    if kind == "work":
        why = "work window"
        if connected:
            why += " (interaction via another device, ignored for the gate)"
        return {"state": "away_work", "why": why,
                "window": kind, "until": until_iso, "absent_confident": True}
    if kind == "sleep":
        if connected:
            return {"state": "nearby",
                    "why": f"sleep window but {connected_why}",
                    "window": kind, "until": until_iso, "absent_confident": False}
        return {"state": "away_sleep", "why": "sleep window, machine idle",
                "window": kind, "until": until_iso, "absent_confident": True}
    return {"state": "nearby", "why": connected_why or "machine idle",
            "window": None, "until": None, "absent_confident": False}


def may_start(state: str | None, absent_confident: bool, connected: bool,
              calm_seconds: float | None, calm_needed: int) -> tuple[bool, str]:
    """The `needs_absence` gate right now: (may start, reason).

    `calm_seconds` = seconds since marc's last activity on tower
    (None = never seen since the dispatcher started: considered calm). The
    gate requires CALM + window: a marc active on the machine blocks even
    during a window (an undeclared remote-work day, for example).
    """
    if state == "at_tower":
        return False, "marc is using tower"
    if absent_confident:
        if calm_seconds is not None and calm_seconds < calm_needed:
            return False, (f"absence window but recent activity from marc "
                           f"({int(calm_seconds)} s)")
        return True, "marc absent (window)"
    if not connected:
        return True, "marc absent (no recent interaction)"
    return False, "marc active (recent interaction)"


def must_stop(state: str | None, absent_confident: bool,
              connected: bool) -> tuple[bool, str]:
    """Should an ongoing `needs_absence` task be interrupted: (yes, reason).

    During a confirmed absence window, only real machine usage
    (at_tower, already computed) interrupts: a message from the phone at the
    office does not cut a job. Outside a window, the original reactive rule
    applies: the first interaction cuts it.
    """
    if state == "at_tower":
        return True, "marc is using tower"
    if not absent_confident and connected:
        return True, "marc is back (recent interaction)"
    return False, ""


def transitions(cfg: dict, overrides: dict, now: dt.datetime,
                count: int = 6) -> list[tuple]:
    """The next window boundaries: [(when, 'start work'), ...]."""
    events: list[tuple] = []
    for ahead in range(-1, 8):
        day = (now + dt.timedelta(days=ahead)).date()
        for kind, start, end in windows_on(cfg, overrides, day):
            for at, label in ((start, f"start {kind}"), (end, f"end {kind}")):
                if at > now:
                    events.append((at, label))
    events.sort(key=lambda item: item[0])
    return events[:count]


def resolve_day(cfg: dict, token: str, now: dt.datetime | None = None) -> dt.date:
    """today | demain | tomorrow | YYYY-MM-DD -> date (config timezone)."""
    now = now or now_local(cfg)
    token = (token or "").strip().lower()
    if token in ("today", "aujourd'hui", "aujourdhui"):
        return now.date()
    if token in ("tomorrow", "demain"):
        return now.date() + dt.timedelta(days=1)
    return dt.date.fromisoformat(token)


def _main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="presence probe (tests)")
    ap.add_argument("--at", help="simulated instant (ISO), forces FAKE_NOW")
    ap.add_argument("--busy", action="store_true", help="simulates high marc cpu")
    ap.add_argument("--tty", metavar="REASON", help="simulates an active marc shell")
    ap.add_argument("--connected", action="store_true",
                    help="simulates a recent hermes interaction")
    ap.add_argument("--config", help="path to presence.json")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--transitions", action="store_true")
    args = ap.parse_args()
    if args.at:
        os.environ["TASKQ_PRESENCE_FAKE_NOW"] = args.at
    cfg = load_config(args.config)
    now = now_local(cfg)
    v = verdict(cfg, {}, now, args.busy, args.tty, args.connected,
                "simulated interaction")
    if args.json:
        print(json.dumps({"at": now.isoformat(timespec="seconds"),
                          **v}, indent=2, ensure_ascii=False))
    else:
        print(f"{now.isoformat(timespec='seconds')} presence={v['state']} "
              f"({v['why']})" + (f" until {v['until']}" if v["until"] else ""))
    if args.transitions:
        for at, label in transitions(cfg, {}, now):
            print(f"  {DAY_NAMES[at.weekday()]} {at:%Y-%m-%d %H:%M} {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
