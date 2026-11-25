#!/usr/bin/env python3
"""Monero miner scheduler.

The service runs as root and applies the rule:
  - weekdays: 01:00-09:00 always, 09:00-18:00 only during an
    event in the Nextcloud work calendar;
  - weekend: 01:00-09:00.
If the calendar is unavailable, the behavior depends on
MONERO_CALENDAR_FAIL_OPEN (default: do not mine during the work window).
"""

from __future__ import annotations

import datetime as dt
import os
import subprocess
import sys


def env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def parse_time(name: str) -> dt.time:
    raw = env(name)
    if raw is None:
        raise SystemExit(f"{name} missing")
    hour, minute = raw.split(":", 1)
    return dt.time(int(hour), int(minute))


def read_secret(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def calendar_event_active(now: dt.datetime) -> bool | None:
    """True if a work event is active, None on error."""
    url = env("MONERO_CALENDAR_URL")
    user_file = env("MONERO_CALENDAR_USER_FILE")
    password_file = env("MONERO_CALENDAR_PASSWORD_FILE")
    names = [
        item.strip().lower()
        for item in (env("MONERO_CALENDAR_NAMES", "sg") or "").split(",")
        if item.strip()
    ]
    if not url or not user_file or not password_file:
        print("calendar: configuration incomplete", flush=True)
        return None

    try:
        import caldav

        client = caldav.DAVClient(
            url=url,
            username=read_secret(user_file),
            password=read_secret(password_file),
        )
        try:
            principal = client.principal()
            for calendar in principal.calendars():
                calendar_url = str(calendar.url).rstrip("/")
                calendar_name = (calendar.name or "").lower()
                if not any(
                    calendar_name == name or calendar_url.endswith("/" + name)
                    for name in names
                ):
                    continue
                events = calendar.search(
                    start=now - dt.timedelta(days=1),
                    end=now + dt.timedelta(days=1),
                    event=True,
                    expand=True,
                )
                for event in events:
                    for component in event.icalendar_instance.walk("VEVENT"):
                        if str(component.get("STATUS", "")).upper() == "CANCELLED":
                            continue
                        start_prop = component.get("DTSTART")
                        if start_prop is None:
                            continue
                        start = start_prop.dt
                        if not isinstance(start, dt.datetime):
                            continue
                        end_prop = component.get("DTEND")
                        end = (
                            end_prop.dt
                            if end_prop is not None
                            else start + dt.timedelta(hours=1)
                        )
                        if not isinstance(end, dt.datetime):
                            continue
                        if start.tzinfo is None:
                            start = start.replace(tzinfo=now.tzinfo)
                        if end.tzinfo is None:
                            end = end.replace(tzinfo=now.tzinfo)
                        if start <= now < end:
                            return True
            print(
                "calendar: no active event in "
                + ",".join(names),
                flush=True,
            )
            return False
        finally:
            close = getattr(client, "close", None)
            if close is not None:
                close()
    except Exception as exc:  # noqa: BLE001 - the detail goes into the log
        print(f"calendar: error {type(exc).__name__}: {exc}", flush=True)
        return None


def main() -> int:
    override = env("MONERO_SCHEDULE_NOW")
    if override is not None:
        now = dt.datetime.fromisoformat(override)
        if now.tzinfo is None:
            now = now.astimezone()
    else:
        now = dt.datetime.now().astimezone()
    weekday = now.isoweekday() <= 5
    current = now.time().replace(tzinfo=None)

    weekday_start = parse_time("MONERO_SCHEDULE_WEEKDAY_START")
    work_start = parse_time("MONERO_SCHEDULE_WEEKDAY_WORK_START")
    weekday_end = parse_time("MONERO_SCHEDULE_WEEKDAY_END")
    weekend_start = parse_time("MONERO_SCHEDULE_WEEKEND_START")
    weekend_end = parse_time("MONERO_SCHEDULE_WEEKEND_END")

    calendar_enabled = env("MONERO_CALENDAR_ENABLE", "0") == "1"
    fail_open = env("MONERO_CALENDAR_FAIL_OPEN", "0") == "1"

    if weekday:
        if weekday_start <= current < work_start:
            desired, reason = True, "sleep"
        elif work_start <= current < weekday_end:
            if calendar_enabled:
                active = calendar_event_active(now)
                if active is None:
                    desired = fail_open
                    reason = "calendar unavailable"
                else:
                    desired = active
                    reason = "work" if active else "outside work"
            else:
                desired, reason = True, "weekday window"
        else:
            desired, reason = False, "outside weekday window"
    else:
        desired = weekend_start <= current < weekend_end
        reason = "weekend window" if desired else "outside weekend window"

    unit = env("MONERO_MINER_UNIT", "monero-miner.service") or "monero-miner.service"
    print(
        f"{now.isoformat()} desired={desired} reason={reason} unit={unit}",
        flush=True,
    )

    if env("MONERO_SCHEDULE_DRY_RUN", "0") == "1":
        return 0

    systemctl = env("MONERO_SYSTEMCTL", "systemctl") or "systemctl"
    active = (
        subprocess.run(
            [systemctl, "is-active", "--quiet", unit],
            check=False,
        ).returncode
        == 0
    )
    if desired and not active:
        rc = subprocess.run([systemctl, "start", unit], check=False).returncode
        print(f"systemctl start {unit} -> {rc}", flush=True)
    elif not desired and active:
        rc = subprocess.run([systemctl, "stop", unit], check=False).returncode
        print(f"systemctl stop {unit} -> {rc}", flush=True)
    else:
        print(f"{unit} already {'active' if active else 'inactive'}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
