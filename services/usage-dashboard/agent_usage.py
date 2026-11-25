#!/usr/bin/env python3
"""Aggregates the LLM usage that Hermes records itself, across all providers.

Single source: state.db (SQLite) of each Hermes profile, table
session_model_usage. One row = (session, model, billing provider,
base URL, task) with the number of API calls, the tokens per category and an
estimated cost. It is the only source that covers ALL providers, including
those whose API publishes no per-model detail (DeepSeek direct, Claude
subscription, local models): the billing APIs only give a balance.

Output: an aggregated JSON intended for the usage-dashboard service, which runs
under another user and therefore must not read state.db itself:
  - series: cost / tokens / calls per day and per provider (graph axis);
  - windows: totals per model, per surface and per task for 1, 7, 30 and N
    days;
  - sessions: one entry per session (title, surface, models, and the same
    daily breakdown as the graph axis) so the page aggregates the
    chosen window in the browser, with no new collection;
  - meta: age of the collection, databases read, volume.

Daily attribution: a session_model_usage row is a session
aggregate, not a dated event (it only carries first_seen and last_seen). We
therefore spread it over the days of the window in proportion to the messages of the
session that day, and failing that over the day of last activity. The total of
the session is kept to the token, only the distribution over time is
approximated: this is stated explicitly in the footer of the web page. The
sum of a session's rows gives back exactly the window total, so
the per-session view cannot diverge from the totals per model.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import providers as prov

HOME = os.environ.get("AGENT_USAGE_HOME", "/var/lib/hermes/.hermes")
OUT = os.environ.get("AGENT_USAGE_OUT", "/var/lib/usage-dashboard-agent/agent-usage.json")
WINDOW_DAYS = int(os.environ.get("AGENT_USAGE_WINDOW_DAYS", "90"))

SQL_USAGE = """
SELECT u.session_id, u.model, u.billing_provider, u.billing_base_url, u.task,
       u.api_call_count, u.input_tokens, u.output_tokens, u.cache_read_tokens,
       u.cache_write_tokens, u.reasoning_tokens,
       u.estimated_cost_usd, u.actual_cost_usd, u.cost_status, u.cost_source,
       u.first_seen, u.last_seen, s.source AS source, s.title AS title
FROM session_model_usage u
LEFT JOIN sessions s ON s.id = u.session_id
WHERE COALESCE(u.last_seen, u.first_seen) >= ?
"""

# Daily weight = number of messages of the session that day.
SQL_WEIGHTS = """
SELECT m.session_id, date(m.timestamp, 'unixepoch') AS d, count(*) AS n
FROM messages m
WHERE m.timestamp >= ? AND m.active = 1
  AND m.session_id IN (
    SELECT DISTINCT session_id FROM session_model_usage
    WHERE COALESCE(last_seen, first_seen) >= ?
  )
GROUP BY 1, 2
"""


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _day(ts: float | None) -> str:
    moment = datetime.fromtimestamp(ts or time.time(), timezone.utc)
    return moment.strftime("%Y-%m-%d")


def _num(value) -> float:
    if isinstance(value, bool) or value is None:
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


STATUS_RANK = {"unknown": 0, "estimated": 1, "actual": 2}


def _best_status(current: str | None, candidate: str) -> str:
    """Keeps the most reliable status of the aggregated rows: actual > estimated > unknown."""
    if STATUS_RANK.get(candidate, 0) > STATUS_RANK.get(current or "unknown", 0):
        return candidate
    return current or candidate


def databases(home: str) -> list[tuple[str, str]]:
    """(profile, path) of each Hermes database readable under this root."""
    found: list[tuple[str, str]] = []
    root = os.path.join(home, "state.db")
    if os.path.exists(root):
        found.append(("default", root))
    profiles = os.path.join(home, "profiles")
    try:
        names = sorted(os.listdir(profiles))
    except OSError:
        names = []
    for name in names:
        path = os.path.join(profiles, name, "state.db")
        if os.path.exists(path):
            found.append((name, path))
    return found


def read_database(path: str, cut: float) -> tuple[list, dict, dict]:
    """Usage rows, daily weights per session, and volume read."""
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=20)
    con.row_factory = sqlite3.Row
    try:
        con.execute("PRAGMA busy_timeout = 20000")
        rows = con.execute(SQL_USAGE, (cut,)).fetchall()
        weights: dict[str, dict[str, int]] = defaultdict(dict)
        for row in con.execute(SQL_WEIGHTS, (cut, cut)):
            weights[row["session_id"]][row["d"]] = int(row["n"] or 0)
    finally:
        con.close()
    volume = {"rows": len(rows), "sessions": len({r["session_id"] for r in rows})}
    return rows, weights, volume


def attribute(row, weights: dict, cut_day: str) -> list[tuple[str, float]]:
    """Distribution of a usage row over the days of the window (fractions)."""
    session_weights = {
        day: count
        for day, count in (weights.get(row["session_id"]) or {}).items()
        if day and day >= cut_day
    }
    total = sum(session_weights.values())
    if total > 0:
        return [(day, count / total) for day, count in sorted(session_weights.items())]
    return [(_day(row["last_seen"] or row["first_seen"]), 1.0)]


def grouped_window(daily: dict, keep) -> dict[str, list]:
    """Sum of the series (key, day) over the retained days, grouped by key."""
    out: dict[str, list] = defaultdict(lambda: [0.0, 0.0, 0.0])
    for (name, day), values in daily.items():
        if not keep(day):
            continue
        slot = out[name]
        for i, value in enumerate(values):
            slot[i] += value
    return out


def main() -> None:
    now = datetime.now(timezone.utc)
    cut = (now - timedelta(days=WINDOW_DAYS)).timestamp()
    cut_day = (now - timedelta(days=WINDOW_DAYS)).strftime("%Y-%m-%d")
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)

    # series[date][provider] = [cost, tokens, calls]
    series: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0, 0.0]))
    # model_daily[(provider, model)][date] = [cost, cost_outside_session, calls,
    #                                        input, output, cache_read, cache_write, reasoning]
    model_daily: dict[tuple[str, str], dict[str, list]] = defaultdict(
        lambda: defaultdict(lambda: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    )
    model_meta: dict[tuple[str, str], dict] = {}
    # source_daily[(surface, date)] = [cost, tokens, calls]
    source_daily: dict[tuple[str, str], list] = defaultdict(lambda: [0.0, 0.0, 0.0])
    # task_daily[(task, date)] = [cost, tokens, calls]
    task_daily: dict[tuple[str, str], list] = defaultdict(lambda: [0.0, 0.0, 0.0])
    total_daily: dict[str, list] = defaultdict(lambda: [0.0, 0.0, 0.0, 0.0])
    # session_daily[session][date] = [cost, tokens, calls] : the per-session view
    # is broken down on the same axis as the graph, so the browser can
    # recompute any window without a new collection.
    session_daily: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0, 0.0]))
    session_meta: dict[str, dict] = {}

    homes: list[dict] = []
    for profile, path in databases(HOME):
        try:
            rows, weights, volume = read_database(path, cut)
        except (sqlite3.Error, OSError) as exc:
            homes.append({"profile": profile, "path": path, "error": f"{type(exc).__name__}: {exc}"})
            continue
        homes.append({"profile": profile, "path": path, **volume, "read_at": _iso(now)})

        for row in rows:
            pid = prov.normalize(row["billing_provider"], row["billing_base_url"])
            model = (row["model"] or "unknown").strip() or "unknown"
            task = (row["task"] or "").strip()
            surface = (row["source"] or "unknown").strip() or "unknown"

            actual = _num(row["actual_cost_usd"])
            estimated = _num(row["estimated_cost_usd"])
            cost = actual if actual > 0 else estimated
            if actual > 0:
                cost_status = "actual"
            elif estimated > 0:
                cost_status = "estimated"
            else:
                cost_status = "unknown"

            tokens_in = _num(row["input_tokens"])
            tokens_out = _num(row["output_tokens"])
            cache_read = _num(row["cache_read_tokens"])
            cache_write = _num(row["cache_write_tokens"])
            tokens = tokens_in + tokens_out + cache_read + cache_write
            aux_cost = cost if task else 0.0

            # Session record: the title comes from the sessions table (set by
            # title generation), the surface is the same as in the
            # "Per surface" view. No date here: the daily breakdown
            # already carries the activity days, the page deduces the first and
            # last day of the chosen window.
            sid = row["session_id"]
            smeta = session_meta.setdefault(sid, {"title": "", "source": surface, "models": {}})
            title = (row["title"] or "").strip()
            if title and not smeta["title"]:
                smeta["title"] = title
            smeta["models"][model] = smeta["models"].get(model, 0.0) + cost

            meta = model_meta.setdefault(
                (pid, model),
                {"first_seen": row["first_seen"], "last_seen": row["last_seen"]},
            )
            if row["first_seen"]:
                meta["first_seen"] = min(meta["first_seen"] or row["first_seen"], row["first_seen"])
            if row["last_seen"]:
                meta["last_seen"] = max(meta["last_seen"] or row["last_seen"], row["last_seen"])
            meta["cost_status"] = _best_status(meta.get("cost_status"), cost_status)
            sources = meta.setdefault("cost_sources", set())
            if row["cost_source"]:
                sources.add(row["cost_source"])

            for day, frac in attribute(row, weights, cut_day):
                slot = series[day][pid]
                slot[0] += cost * frac
                slot[1] += tokens * frac
                slot[2] += _num(row["api_call_count"]) * frac

                mslot = model_daily[(pid, model)][day]
                mslot[0] += cost * frac
                mslot[1] += aux_cost * frac
                mslot[2] += _num(row["api_call_count"]) * frac
                mslot[3] += tokens_in * frac
                mslot[4] += tokens_out * frac
                mslot[5] += cache_read * frac
                mslot[6] += cache_write * frac
                mslot[7] += _num(row["reasoning_tokens"]) * frac

                sslot = source_daily[(surface, day)]
                sslot[0] += cost * frac
                sslot[1] += tokens * frac
                sslot[2] += _num(row["api_call_count"]) * frac

                tslot = total_daily[day]
                tslot[0] += cost * frac
                tslot[1] += tokens * frac
                tslot[2] += _num(row["api_call_count"]) * frac
                tslot[3] += aux_cost * frac

                if task:
                    kslot = task_daily[(task, day)]
                    kslot[0] += cost * frac
                    kslot[1] += tokens * frac
                    kslot[2] += _num(row["api_call_count"]) * frac

                session_slot = session_daily[sid][day]
                session_slot[0] += cost * frac
                session_slot[1] += tokens * frac
                session_slot[2] += _num(row["api_call_count"]) * frac

    # Continuous axis: all days of the window, even empty ones.
    days: list[str] = []
    cursor = datetime.strptime(cut_day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    last = today.strftime("%Y-%m-%d")
    while cursor.strftime("%Y-%m-%d") <= last:
        days.append(cursor.strftime("%Y-%m-%d"))
        cursor += timedelta(days=1)

    series_out = []
    for day in days:
        providers = series.get(day) or {}
        series_out.append(
            {
                "date": day,
                "p": {
                    pid: [round(v[0], 6), int(round(v[1])), int(round(v[2]))]
                    for pid, v in providers.items()
                },
            }
        )

    # Same axis, but key "provider|model": used for the graph stacked by model.
    series_model = []
    for day in days:
        row = {}
        for (pid, model), per_day in model_daily.items():
            values = per_day.get(day)
            if not values:
                continue
            row[f"{pid}|{model}"] = [
                round(values[0], 6),
                int(round(values[3] + values[4] + values[5] + values[6])),
            ]
        series_model.append({"date": day, "m": row})

    windows = {}
    for span in (1, 7, 30, WINDOW_DAYS):
        start = (today - timedelta(days=span - 1)).strftime("%Y-%m-%d")
        keep = lambda day: day >= start  # noqa: E731

        models = []
        for (pid, model), per_day in model_daily.items():
            agg = [0.0] * 8
            used = False
            for day, values in per_day.items():
                if not keep(day):
                    continue
                used = True
                for i, value in enumerate(values):
                    agg[i] += value
            if not used:
                continue
            meta = model_meta.get((pid, model)) or {}
            models.append(
                {
                    "model": model,
                    "provider": pid,
                    "cost": round(agg[0], 6),
                    "aux_cost": round(agg[1], 6),
                    "calls": int(round(agg[2])),
                    "tokens_in": int(round(agg[3])),
                    "tokens_out": int(round(agg[4])),
                    "cache_read": int(round(agg[5])),
                    "cache_write": int(round(agg[6])),
                    "reasoning": int(round(agg[7])),
                    "tokens": int(round(agg[3] + agg[4] + agg[5] + agg[6])),
                    "cost_status": meta.get("cost_status") or "unknown",
                    "cost_source": ", ".join(sorted(meta.get("cost_sources") or [])),
                    "last_seen": _iso(datetime.fromtimestamp(meta["last_seen"], timezone.utc))
                    if meta.get("last_seen")
                    else None,
                }
            )
        models.sort(key=lambda m: (m["cost"], m["tokens"]), reverse=True)

        sources_out = sorted(
            (
                {
                    "surface": surface,
                    "cost": round(v[0], 6),
                    "tokens": int(round(v[1])),
                    "calls": int(round(v[2])),
                }
                for surface, v in grouped_window(source_daily, keep).items()
            ),
            key=lambda s: s["cost"],
            reverse=True,
        )

        tasks = sorted(
            (
                {
                    "task": task,
                    "cost": round(v[0], 6),
                    "tokens": int(round(v[1])),
                    "calls": int(round(v[2])),
                }
                for task, v in grouped_window(task_daily, keep).items()
            ),
            key=lambda t: t["cost"],
            reverse=True,
        )

        total = [0.0, 0.0, 0.0, 0.0]
        for day, values in total_daily.items():
            if not keep(day):
                continue
            for i, value in enumerate(values):
                total[i] += value
        windows[str(span)] = {
            "start": start,
            "models": models,
            "sources": sources_out,
            "tasks": tasks,
            "totals": {
                "cost": round(total[0], 6),
                "tokens": int(round(total[1])),
                "calls": int(round(total[2])),
                "aux_cost": round(total[3], 6),
            },
        }

    # Per-session view: one entry per session, with the same daily
    # breakdown as the graph axis. The browser sums the days of the
    # chosen window, so changing window (24 h, 7, 30, 90 d) requires
    # no new collection. Sessions with no cost or token (old
    # rows without a known rate) are dropped: they would teach nothing.
    sessions_out: list[dict] = []
    for sid, per_day in session_daily.items():
        cost = sum(v[0] for v in per_day.values())
        tokens = sum(v[1] for v in per_day.values())
        if cost <= 0 and tokens <= 0:
            continue
        smeta = session_meta.get(sid) or {}
        models = sorted(
            (smeta.get("models") or {}).items(), key=lambda item: item[1], reverse=True
        )
        sessions_out.append(
            {
                "id": sid,
                "title": smeta.get("title") or "",
                "source": smeta.get("source") or "unknown",
                "models": [[name, round(value, 6)] for name, value in models],
                "days": {
                    day: [round(v[0], 6), int(round(v[1])), int(round(v[2]))]
                    for day, v in sorted(per_day.items())
                },
            }
        )
    sessions_out.sort(
        key=lambda s: (
            sum(v[0] for v in s["days"].values()),
            sum(v[1] for v in s["days"].values()),
        ),
        reverse=True,
    )

    payload = {
        "generated_at": _iso(now),
        "window_days": WINDOW_DAYS,
        "homes": homes,
        "series": series_out,
        "series_model": series_model,
        "sessions": sessions_out,
        "windows": windows,
    }

    os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
    print(
        f"[agent-usage] {len(days)} days, {len(windows[str(WINDOW_DAYS)]['models'])} models, "
        f"{len(sessions_out)} sessions, "
        f"cost {WINDOW_DAYS} d = ${windows[str(WINDOW_DAYS)]['totals']['cost']:.2f} -> {OUT}",
        flush=True,
    )


if __name__ == "__main__":
    main()
