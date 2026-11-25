"""Claude subscription plan limits (same numbers as Claude Code /usage).

Reads the Claude Code OAuth token of the hermes user and queries
https://api.anthropic.com/api/oauth/usage, then writes a small JSON file for
the web service. The token is only READ: it is never refreshed here, because a
refresh rotates the refresh token and would log Claude Code out. When the
access token is expired, the file says so and keeps the last good numbers.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

CREDS = os.environ.get("CLAUDE_PLAN_CREDENTIALS", "")
OUT = os.environ.get("CLAUDE_PLAN_OUT", "")
URL = "https://api.anthropic.com/api/oauth/usage"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_previous() -> dict:
    try:
        with open(OUT, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write(payload: dict) -> None:
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)


def window(raw) -> dict | None:
    if not isinstance(raw, dict) or raw.get("utilization") is None:
        return None
    return {"percent": raw.get("utilization"), "resets_at": raw.get("resets_at")}


def main() -> int:
    if not OUT:
        print("CLAUDE_PLAN_OUT not set", file=sys.stderr)
        return 1
    previous = read_previous()
    result = {"checked_at": now_iso(), "state": "error", "message": None, "data": previous.get("data"),
              "fetched_at": previous.get("fetched_at")}
    try:
        with open(CREDS, encoding="utf-8") as fh:
            oauth = (json.load(fh) or {}).get("claudeAiOauth") or {}
        token = oauth.get("accessToken")
        if not token:
            raise ValueError("no accessToken in credentials")
        if oauth.get("expiresAt") and oauth["expiresAt"] / 1000 < time.time():
            result["state"] = "stale"
            result["message"] = "OAuth token expired (refreshed by Claude Code on next use)"
            write(result)
            return 0
        req = urllib.request.Request(
            URL,
            headers={
                "Authorization": "Bearer " + token,
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "hermes-research",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        result["message"] = f"HTTP {exc.code}"
        write(result)
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        result["message"] = f"{type(exc).__name__}: {exc}"
        write(result)
        return 0

    breakdown = raw.get("seven_day_breakdown") or {}
    extra = raw.get("extra_usage") or {}
    data = {
        "session": window(raw.get("five_hour")),
        "weekly": window(raw.get("seven_day")),
        "weekly_opus": window(raw.get("seven_day_opus")),
        "weekly_sonnet": window(raw.get("seven_day_sonnet")),
        "breakdown": [
            {"name": r.get("display_name") or r.get("key"), "share": r.get("percent"),
             "percent_of_limit": r.get("percent_of_limit")}
            for r in (breakdown.get("rows") or [])
        ],
        "extra_usage": {
            "enabled": extra.get("is_enabled"),
            "used": extra.get("used_credits"),
            "limit": extra.get("monthly_limit"),
            "currency": extra.get("currency"),
        } if extra else None,
    }
    result.update({"state": "ok", "message": None, "data": data, "fetched_at": result["checked_at"]})
    write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
