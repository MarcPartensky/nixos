#!/usr/bin/env python3
"""LLM usage dashboard, centered on the providers and not on a single one.

Three sources, three roles:

  1. Real usage recorded by Hermes (agent-usage.json, produced by
     agent_usage.py under the hermes user): it is the only source that
     covers ALL the providers and gives the detail per model, per surface and
     per day, including for those whose billing API publishes nothing
     other than a balance (DeepSeek direct, Claude subscription, local models).
     The cost there is ESTIMATED from Hermes's known rates.

  2. Billing API balances, when they expose one:
       - OpenRouter /credits (credits purchased / consumed / remaining)
       - OpenRouter /key     (real-time usage of the inference key)
       - Moonshot /users/me/balance
       - DeepSeek /user/balance
     It is the only REAL cost available, and it exists only at the account level.

  3. Balance history, kept by this service: by comparing the samples over
     time we get the REAL consumption per provider without depending on a
     detailed billing endpoint. This is what allows saying how much
     credit a provider consumes per day, and how many days are left.

A cost is therefore always labeled: "real" (balance), "estimated" (Hermes rates)
or "equivalent" (subscription: what the usage would cost at the API rate, without being
billed per token). The page never mixes the three in a single total.

No dependency outside the stdlib. The page is served static and queries
/api/data: the refresh is on the browser side, so an open page
stays up to date without redeployment.
"""

from __future__ import annotations

import gzip
import ipaddress
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import providers as prov

HOST = os.environ.get("USAGE_DASHBOARD_HOST", "0.0.0.0")
PORT = int(os.environ.get("USAGE_DASHBOARD_PORT", "9141"))
PAGE_FILE = os.environ.get("USAGE_DASHBOARD_PAGE", "")
STATE_FILE = os.environ.get("USAGE_DASHBOARD_STATE", "")
HISTORY_FILE = os.environ.get("USAGE_DASHBOARD_HISTORY", "")
AGENT_FILE = os.environ.get("USAGE_DASHBOARD_AGENT_FILE", "")
CLAUDE_PLAN_FILE = os.environ.get("USAGE_DASHBOARD_CLAUDE_PLAN_FILE", "")
MGMT_KEY_FILE = os.environ.get("USAGE_DASHBOARD_MANAGEMENT_KEY_FILE", "")
INFER_KEY_FILE = os.environ.get("USAGE_DASHBOARD_INFERENCE_KEY_FILE", "")
MOONSHOT_KEY_FILE = os.environ.get("USAGE_DASHBOARD_MOONSHOT_KEY_FILE", "")
DEEPSEEK_KEY_FILE = os.environ.get("USAGE_DASHBOARD_DEEPSEEK_KEY_FILE", "")
GEMINI_KEY_FILE = os.environ.get("USAGE_DASHBOARD_GEMINI_KEY_FILE", "")
REFRESH = float(os.environ.get("USAGE_DASHBOARD_REFRESH", "120"))
WINDOW_DAYS = int(os.environ.get("USAGE_DASHBOARD_WINDOW_DAYS", "90"))
# Model tested if no gemini usage is recorded in the window.
GEMINI_PROBE_MODEL = os.environ.get("USAGE_DASHBOARD_GEMINI_PROBE_MODEL", "gemini-3.8-flash")
# Cadence of the probe's generation call: it consumes quota at
# Google (limits per minute AND per day, even on the free tier), so one
# try per hour is largely enough to see an outage.
GEMINI_GEN_EVERY = float(os.environ.get("USAGE_DASHBOARD_GEMINI_GEN_EVERY", "3600"))
GEMINI_GEN_TIMEOUT = int(os.environ.get("USAGE_DASHBOARD_GEMINI_GEN_TIMEOUT", "25"))
SUBSCRIPTIONS = json.loads(os.environ.get("USAGE_DASHBOARD_SUBSCRIPTIONS", "[]") or "[]")

OR_API = "https://openrouter.ai/api/v1"
MOONSHOT_API = "https://api.moonshot.ai/v1"
DEEPSEEK_API = "https://api.deepseek.com"
GEMINI_API = "https://generativelanguage.googleapis.com/v1beta"
FX_URL = "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR,CNY"

# Never marc's name in a User-Agent.
UA = "hermes-research/1.0"

# Balance sample: at most one point per hour, kept for a year.
SAMPLE_EVERY = 3600
SAMPLE_KEEP_DAYS = 400

SPANS = (1, 7, 30, WINDOW_DAYS)

_lock = threading.Lock()
_cache: dict = {"payload": None, "payload_public": None, "fetched_at": 0.0}
_page_cache: dict = {"body": None, "mtime": 0.0}

# The public domain is open (no Pangolin SSO): the session titles
# are personal, so they only go to a client coming DIRECTLY from the
# tailnet. Pangolin arrives via newt from 127.0.0.1, so a local request
# is not a trusted client: it may come from the Internet.
TAILNET = ipaddress.ip_network("100.64.0.0/10")


def _trusted_client(address: str) -> bool:
    try:
        return ipaddress.ip_address(address) in TAILNET
    except ValueError:
        return False


def public_view(payload: dict) -> dict:
    """Copy of the payload served outside the tailnet: session titles removed.

    The rest (session id, surface, dominant model, cost, tokens) is an
    aggregate without secrets and goes as is. Computed once per collection.
    """
    sessions = [
        {**s, "title": ""} if s.get("title") else s for s in (payload.get("sessions") or [])
    ]
    return {**payload, "sessions": sessions}


# --------------------------------------------------------------------------
# low level
# --------------------------------------------------------------------------
def _read_secret(path: str) -> str | None:
    """Reads a secret from a file. An unreplaced placeholder counts as absent.

    The file contains either the value alone (secrets/deepseek.yml), or a
    dotenv line "KEY=value" (secrets/hermes-gemini.yml, the same file as
    the one rendered in the agent's .env): in that case only the
    value is kept, otherwise the HTTP header would go out with "GOOGLE_API_KEY=" in front.
    """
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return None
    match = re.match(r"^[A-Z][A-Z0-9_]{2,}=(.*)$", value, re.DOTALL)
    if match:
        value = match.group(1).strip()
    if not value or value.upper().startswith("PLACEHOLDER"):
        return None
    return value


def _http(url: str, key: str | None = None, payload: dict | None = None, timeout: int = 20):
    """Returns (data, None) or (None, readable error message)."""
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method="POST" if body else "GET")
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "application/json")
    if body:
        req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
        return json.loads(raw), None
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read(400).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            detail = ""
        return None, f"HTTP {exc.code} {detail}".strip()
    except Exception as exc:  # noqa: BLE001
        return None, f"{type(exc).__name__}: {exc}"


def _num(value) -> float:
    """API counters arrive as a number OR as a string: accept both."""
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return 0.0


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_json(path: str):
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def _write_json(path: str, payload) -> None:
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError as exc:
        print(f"[usage-dashboard] cannot write {path}: {exc}", flush=True)


# --------------------------------------------------------------------------
# balance history: real consumption without a billing endpoint
# --------------------------------------------------------------------------
def load_history() -> dict:
    data = _read_json(HISTORY_FILE) or {}
    samples = data.get("samples") if isinstance(data, dict) else None
    return samples if isinstance(samples, dict) else {}


def record_samples(samples: dict, balances: dict[str, dict], now: datetime) -> dict:
    """Adds one point per provider (at most one per hour) and prunes the old ones."""
    stamp = now.timestamp()
    cut = stamp - SAMPLE_KEEP_DAYS * 86400
    for pid, balance in balances.items():
        amount = balance.get("amount")
        if amount is None:
            continue
        points = [p for p in samples.get(pid, []) if isinstance(p, list) and len(p) >= 2 and p[0] >= cut]
        if points and stamp - points[-1][0] < SAMPLE_EVERY:
            points[-1] = [stamp, round(float(amount), 6)]
        else:
            points.append([stamp, round(float(amount), 6)])
        samples[pid] = points
    return samples


def consumption(samples: list, now: datetime, days: int) -> dict | None:
    """Consumption deduced from the drop in the balance (top-ups are ignored).

    The balance only drops when the provider bills: the sum of the drops over
    the period is therefore money really spent, without depending on a
    detail per model. A rise is a top-up, not a consumption.
    """
    if not samples:
        return None
    cut = now.timestamp() - days * 86400
    points = [[p[0], p[1]] for p in samples if isinstance(p, list) and len(p) >= 2 and p[0] >= cut]
    if len(points) < 2:
        return None
    span = (points[-1][0] - points[0][0]) / 86400.0
    if span < 0.5:
        return None
    spent = 0.0
    for (_, before), (_, after) in zip(points, points[1:]):
        if after < before:
            spent += before - after
    return {
        "usd": round(spent, 4),
        "span_days": round(span, 2),
        "per_day": round(spent / span, 4) if span > 0 else None,
        "from": _iso(datetime.fromtimestamp(points[0][0], timezone.utc)),
        "points": len(points),
    }


# --------------------------------------------------------------------------
# gemini probe
# --------------------------------------------------------------------------
# Google exposes no balance endpoint (the API gives the quota, not the remaining
# credit): the equivalent of the "balance" card of the other providers is therefore
# a health probe. Two stages, because they are two different outages:
#   - GET /v1beta/models: free and fast, it proves that the key is still
#     accepted and that the models actually used are still offered
#     (a model removed from the tier answers 404 on generation while remaining
#     in the usage samples);
#   - POST generateContent on the last model used: the only probe that
#     sees a 429 of exhausted quota, a saturated model (503) or a timeout. One
#     try per hour (8 tokens) is enough to see an outage without burning the quota.
_gemini_gen: dict = {"at": 0.0, "result": None}


def _gemini_call(path: str, key: str, payload: dict | None = None, timeout: int = 20):
    """(code, data, message, latency_ms). x-goog-api-key header, never Bearer."""
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"{GEMINI_API}/{path}", data=body, method="POST" if body else "GET")
    req.add_header("x-goog-api-key", key)
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "application/json")
    if body:
        req.add_header("Content-Type", "application/json")
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.load(resp), None, int((time.time() - started) * 1000)
    except urllib.error.HTTPError as exc:
        raw = ""
        try:
            raw = exc.read(400).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            pass
        message = _google_error(raw) or f"HTTP {exc.code}"
        return exc.code, None, message, int((time.time() - started) * 1000)
    except Exception as exc:  # noqa: BLE001
        return None, None, f"{type(exc).__name__}: {exc}", int((time.time() - started) * 1000)


def _google_error(raw: str) -> str:
    """"429 RESOURCE_EXHAUSTED: You exceeded your current quota" from the JSON body."""
    try:
        err = (json.loads(raw) or {}).get("error") or {}
    except (json.JSONDecodeError, AttributeError, TypeError):
        return ""
    first = (err.get("message") or "").strip().split("\n")[0]
    label = err.get("status") or err.get("code")
    if not first:
        return ""
    return f"{label}: {first}"[:220] if label else first[:220]


def _gemini_models_used(payload: dict, limit: int = 3) -> list[str]:
    """Gemini models actually used, from the most recently seen to the oldest."""
    windows = payload.get("windows") or {}
    win = windows.get("7") or windows.get("30") or {}
    rows = [m for m in (win.get("models") or []) if m.get("provider") == "gemini"]
    rows.sort(key=lambda m: m.get("last_seen") or "", reverse=True)
    return [m["model"] for m in rows[:limit] if m.get("model")]


def _gemini_generate(key: str, model: str, now: datetime) -> dict:
    body = {"contents": [{"parts": [{"text": "ping"}]}], "generationConfig": {"maxOutputTokens": 8}}
    code, data, message, latency = _gemini_call(
        f"models/{model}:generateContent", key, payload=body, timeout=GEMINI_GEN_TIMEOUT
    )
    out: dict = {"model": model, "checked_at": _iso(now), "latency_ms": latency, "http": code}
    if code == 200:
        usage = (data or {}).get("usageMetadata") or {}
        out["state"] = "ok"
        out["tokens"] = usage.get("totalTokenCount")
    else:
        out["state"] = "timeout" if code is None else "error"
        out["message"] = message
    return out


def probe_gemini(key: str, models_used: list[str], now: datetime) -> dict:
    """State of the gemini provider: key, models used, real generation."""
    health: dict = {
        "checked_at": _iso(now),
        "key_ok": False,
        "models_listed": 0,
        "latency_ms": None,
        "state": "error",
        "detail": [],
        "models_used": [],
        "gen": None,
    }
    code, data, message, latency = _gemini_call("models", key, timeout=15)
    health["latency_ms"] = latency
    if code != 200:
        health["detail"].append(f"key refused ({message})")
        return health

    names = [(m.get("name") or "").split("/")[-1] for m in (data or {}).get("models", [])]
    health["key_ok"] = True
    health["models_listed"] = len(names)
    health["detail"].append(f"{len(names)} models listed in {latency} ms")
    missing = []
    for model in models_used:
        listed = model in names
        health["models_used"].append({"model": model, "listed": listed})
        if not listed:
            missing.append(model)
    if missing:
        health["detail"].append("no longer offered: " + ", ".join(missing))

    target = models_used[0] if models_used else GEMINI_PROBE_MODEL
    cached = _gemini_gen.get("result")
    fresh = bool(
        cached
        and cached.get("model") == target
        and (now.timestamp() - float(_gemini_gen.get("at") or 0.0)) < GEMINI_GEN_EVERY
    )
    if fresh:
        health["gen"] = cached
    else:
        health["gen"] = _gemini_generate(key, target, now)
        _gemini_gen["at"] = now.timestamp()
        _gemini_gen["result"] = health["gen"]

    gen = health["gen"] or {}
    if gen.get("state") == "ok" and not missing:
        health["state"] = "ok"
        health["detail"].append(f"generation OK on {gen.get('model')} in {gen.get('latency_ms')} ms")
    else:
        health["state"] = "degraded"
        reason = gen.get("message") or ("model removed from the offering" if missing else "no generation tested")
        health["detail"].append(f"generation {gen.get('state') or 'not tested'} on {target}: {reason}"[:220])
    return health


# --------------------------------------------------------------------------
# collection
# --------------------------------------------------------------------------
def collect_balances(now: datetime, note) -> tuple[dict, dict]:
    """Balances per provider. Returns (balances, extra) where extra carries the details."""
    balances: dict[str, dict] = {}
    extra: dict = {"openrouter": None}

    mgmt = _read_secret(MGMT_KEY_FILE)
    infer = _read_secret(INFER_KEY_FILE)

    # 1. OpenRouter: the balance does not depend on the key role, /credits answers
    #    to both. We take the first available one.
    credits_key = mgmt or infer
    if credits_key:
        data, err = _http(f"{OR_API}/credits", key=credits_key)
        if err:
            note("openrouter/credits", "error", err)
        else:
            info = (data or {}).get("data") or {}
            total = _num(info.get("total_credits"))
            used = _num(info.get("total_usage"))
            balances["openrouter"] = {
                "amount": round(max(0.0, total - used), 6) if abs(total - used) < 0.01 else round(total - used, 6),
                "currency": "USD",
                "source": "/api/v1/credits",
                "used_pct": round(100.0 * used / total, 2) if total > 0 else 0.0,
                "detail": [
                    f"{total:.2f} purchased",
                    f"{used:.2f} consumed",
                ],
            }
            note("openrouter/credits", "ok")
    else:
        note("openrouter/credits", "missing", "no readable OpenRouter key")

    # 2. OpenRouter: real-time usage of the inference key (day/week/month).
    key_usage = None
    if infer:
        data, err = _http(f"{OR_API}/key", key=infer)
        if err:
            note("openrouter/key", "error", err)
        else:
            info = (data or {}).get("data") or {}
            key_usage = {
                "label": info.get("label"),
                "usage": _num(info.get("usage")),
                "usage_daily": _num(info.get("usage_daily")),
                "usage_weekly": _num(info.get("usage_weekly")),
                "usage_monthly": _num(info.get("usage_monthly")),
                "limit": _num(info["limit"]) if info.get("limit") is not None else None,
                "expires_at": info.get("expires_at"),
            }
            note("openrouter/key", "ok")
    else:
        note("openrouter/key", "missing", "inference key absent (real-time usage unavailable)")

    # 3. Moonshot (kimi direct).
    moonshot = _read_secret(MOONSHOT_KEY_FILE)
    if moonshot:
        data, err = _http(f"{MOONSHOT_API}/users/me/balance", key=moonshot, timeout=15)
        if err:
            note("moonshot", "error", err)
        else:
            info = (data or {}).get("data") or {}
            balances["moonshot"] = {
                "amount": _num(info.get("available_balance")),
                "currency": "USD",
                "source": "/users/me/balance",
                "detail": [
                    f"vouchers {_num(info.get('voucher_balance')):.2f}",
                    f"cash {_num(info.get('cash_balance')):.2f}",
                ],
            }
            note("moonshot", "ok")
    else:
        note("moonshot", "missing", "Moonshot key absent (kimi direct not tracked)")

    # 4. DeepSeek direct: an API key reads ONLY the balance (the detail per
    #    key/day exists only on the console, behind a login).
    deepseek = _read_secret(DEEPSEEK_KEY_FILE)
    if deepseek:
        data, err = _http(f"{DEEPSEEK_API}/user/balance", key=deepseek, timeout=15)
        if err:
            note("deepseek", "error", err)
        else:
            infos = (data or {}).get("balance_infos") or []
            info = infos[0] if infos else {}
            balances["deepseek"] = {
                "amount": _num(info.get("total_balance")),
                "currency": info.get("currency") or "USD",
                "source": "/user/balance",
                "detail": [
                    f"granted {_num(info.get('granted_balance')):.2f}",
                    f"top-up {_num(info.get('topped_up_balance')):.2f}",
                ],
                "usable": bool((data or {}).get("is_available")),
            }
            note("deepseek", "ok")
    else:
        note("deepseek", "missing", "DeepSeek key absent (direct account not tracked)")

    # 5. Exchange rate (no key, cosmetic: a failure breaks nothing).
    data, err = _http(FX_URL, timeout=12)
    if err:
        note("frankfurter", "error", err)
    else:
        rates = (data or {}).get("rates") or {}
        if rates.get("EUR"):
            extra["fx"] = {
                "usd_eur": _num(rates["EUR"]),
                "usd_cny": _num(rates.get("CNY")) or None,
                "date": (data or {}).get("date"),
            }
            note("frankfurter", "ok")
        else:
            note("frankfurter", "error", "no EUR rate in the response")

    # 6. OpenRouter analytics: cross-check of the cost estimated by Hermes.
    #    Management key mandatory (read-only, free). Without it, the
    #    rest of the page works: it is only a cross-reference.
    analytics = None
    if mgmt:
        start = now - timedelta(days=min(WINDOW_DAYS, 30))
        rows, err = _analytics_query(
            mgmt,
            ["total_usage", "request_count", "tokens_total"],
            start=start,
            end=now,
            limit=1,
        )
        if err:
            note("openrouter/analytics", "error", err)
        else:
            row = rows[0] if rows else {}
            analytics = {
                "window_days": min(WINDOW_DAYS, 30),
                "usage": _num(row.get("total_usage")),
                "requests": _num(row.get("request_count")),
                "tokens": _num(row.get("tokens_total")),
            }
            note("openrouter/analytics", "ok")
    else:
        note(
            "openrouter/analytics",
            "missing",
            "management key absent: no cross-check of the OpenRouter cost",
        )

    extra["openrouter"] = {"analytics": analytics, "key": key_usage}
    return balances, extra


def _analytics_query(key: str, metrics: list[str], start, end, limit: int = 100,
                     dimensions: list[str] | None = None, granularity: str | None = None):
    body: dict = {
        "metrics": metrics,
        "time_range": {"start": _iso(start), "end": _iso(end)},
        "limit": limit,
    }
    if dimensions:
        body["dimensions"] = dimensions
    if granularity:
        body["granularity"] = granularity
    data, err = _http(f"{OR_API}/analytics/query", key=key, payload=body)
    if err:
        return [], err
    rows = ((data or {}).get("data") or {}).get("data") or []
    return rows, None


def provider_rollup(agent: dict) -> dict[str, dict[str, dict]]:
    """Totals per provider and per window, derived from the totals per model."""
    rollup: dict[str, dict[str, dict]] = {}
    windows = (agent or {}).get("windows") or {}
    for span in SPANS:
        block = windows.get(str(span)) or {}
        models = block.get("models") or []
        for row in models:
            pid = row.get("provider") or "unknown"
            slot = rollup.setdefault(pid, {}).setdefault(
                str(span), {"cost": 0.0, "tokens": 0, "calls": 0, "aux_cost": 0.0, "models": 0}
            )
            slot["cost"] += _num(row.get("cost"))
            slot["aux_cost"] += _num(row.get("aux_cost"))
            slot["tokens"] += int(_num(row.get("tokens")))
            slot["calls"] += int(_num(row.get("calls")))
            slot["models"] += 1
    for pid, spans in rollup.items():
        for slot in spans.values():
            slot["cost"] = round(slot["cost"], 6)
            slot["aux_cost"] = round(slot["aux_cost"], 6)
    return rollup


def collect() -> dict:
    now = datetime.now(timezone.utc)
    payload: dict = {
        "generated_at": _iso(now),
        "window_days": WINDOW_DAYS,
        "spans": list(SPANS),
        "status": {},
        "errors": [],
        "fx": None,
        "agent": None,
        "providers": [],
        "provider_meta": {},
        "provider_windows": {},
        "series": [],
        "windows": {},
        "sessions": [],
        "health": {},
        "openrouter": None,
        "subscriptions": SUBSCRIPTIONS,
    }

    def note(source: str, state: str, message: str | None = None) -> None:
        payload["status"][source] = {"state": state, "message": message}
        if state == "error":
            payload["errors"].append(f"{source}: {message}")

    balances, extra = collect_balances(now, note)
    payload["fx"] = extra.get("fx")
    payload["openrouter"] = extra.get("openrouter")

    # Usage recorded by Hermes.
    agent = _read_json(AGENT_FILE)
    if not isinstance(agent, dict):
        note("hermes/usage", "error", f"unreadable usage file ({AGENT_FILE or 'not configured'})")
        agent = {}
    else:
        stamp = agent.get("generated_at")
        age = None
        try:
            if isinstance(stamp, str):
                age = round(
                    (
                        now
                        - datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                    ).total_seconds()
                )
        except ValueError:
            pass
        payload["series"] = agent.get("series") or []
        payload["series_model"] = agent.get("series_model") or []
        # Detail per session: ~290 KB raw, ~70 KB compressed, and it only moves
        # at the collector's pace (5 min). The page aggregates it on the browser side
        # for the chosen window, so no extra round-trip.
        payload["sessions"] = agent.get("sessions") or []
        payload["windows"] = agent.get("windows") or {}
        payload["agent"] = {
            "generated_at": stamp,
            "age_seconds": age,
            "window_days": agent.get("window_days"),
            "homes": agent.get("homes") or [],
        }
        note("hermes/usage", "ok", None if (age is None or age < 1800) else f"collection {age // 60} min old")

    # Claude plan limits (claude_plan.py collector).
    plan = _read_json(CLAUDE_PLAN_FILE) if CLAUDE_PLAN_FILE else None
    if isinstance(plan, dict):
        payload["claude_plan"] = plan
        state = plan.get("state")
        note("claude/plan", "ok" if state == "ok" else ("missing" if state == "stale" else "error"), plan.get("message"))
    elif CLAUDE_PLAN_FILE:
        note("claude/plan", "missing", "no sample yet")

    # Health of the gemini provider. Google has no balance to read (no credit
    # endpoint), so the card carries a probe: key accepted, models used
    # still offered, and a real generation. It needs the gemini models
    # actually used, hence its place after reading the Hermes usage.
    gemini_key = _read_secret(GEMINI_KEY_FILE)
    if gemini_key:
        health = probe_gemini(gemini_key, _gemini_models_used(payload), now)
        payload["health"]["gemini"] = health
        note(
            "gemini/health",
            "ok" if health["state"] == "ok" else "error",
            None if health["state"] == "ok" else " · ".join(health["detail"][-2:])[:220],
        )
    elif GEMINI_KEY_FILE:
        note("gemini/health", "missing", "Gemini key absent: provider health not monitored")

    rollup = provider_rollup(agent)
    histories = load_history()
    histories = record_samples(histories, balances, now)
    if HISTORY_FILE:
        _write_json(HISTORY_FILE, {"version": 1, "samples": histories})

    # Providers to display: those that have usage, a balance, or a known
    # registry entry with a key present.
    ids = set(rollup)
    ids.update(balances)
    if _read_secret(INFER_KEY_FILE) or _read_secret(MGMT_KEY_FILE):
        ids.add("openrouter")
    if _read_secret(DEEPSEEK_KEY_FILE):
        ids.add("deepseek")
    if _read_secret(MOONSHOT_KEY_FILE):
        ids.add("moonshot")
    if _read_secret(GEMINI_KEY_FILE):
        ids.add("gemini")

    provider_meta = {pid: prov.meta(pid) for pid in ids}
    payload["provider_meta"] = provider_meta

    total_cash_30 = 0.0
    total_sub_30 = 0.0

    for pid in ids:
        meta = provider_meta[pid]
        spans = rollup.get(pid, {})
        month = spans.get("30") or {"cost": 0.0, "tokens": 0, "calls": 0, "aux_cost": 0.0, "models": 0}
        balance = balances.get(pid)
        burn = consumption(histories.get(pid, []), now, 30)
        burn_week = consumption(histories.get(pid, []), now, 7)
        if burn:
            burn["source"] = "history"
        elif month["cost"] > 0:
            # No long enough balance history yet: we fall back on the
            # cost estimated by Hermes, saying so (source = estimate).
            burn = {
                "usd": round(month["cost"], 4),
                "span_days": 30,
                "per_day": round(month["cost"] / 30.0, 4),
                "from": None,
                "points": 0,
                "source": "estimate",
            }
        runway = None
        if balance and burn and burn.get("per_day"):
            amount = balance.get("amount") or 0.0
            runway = round(amount / burn["per_day"], 1) if burn["per_day"] > 0 else None

        top_model = None
        block = (payload["windows"].get("30") or {}).get("models") or []
        candidates = [m for m in block if m.get("provider") == pid and _num(m.get("cost")) > 0]
        if candidates:
            best = candidates[0]
            top_model = {"model": best.get("model"), "cost": round(_num(best.get("cost")), 4)}

        payload["providers"].append(
            {
                "id": pid,
                "label": meta["label"],
                "kind": meta["kind"],
                "color": meta["color"],
                "note": meta["note"],
                "balance": balance,
                "burn_30": burn,
                "burn_7": burn_week,
                "runway_days": runway,
                "history_points": len(histories.get(pid, [])),
                "history_since": _iso(datetime.fromtimestamp(histories[pid][0][0], timezone.utc))
                if histories.get(pid)
                else None,
                "windows": {str(span): spans.get(str(span)) for span in SPANS},
                "month": month,
                "top_model": top_model,
                "equivalent_only": meta["kind"] == "subscription",
            }
        )
        if meta["kind"] == "subscription":
            total_sub_30 += month["cost"]
        elif meta["kind"] in ("cash", "other"):
            total_cash_30 += month["cost"]

    payload["provider_windows"] = {
        pid: {str(span): spans.get(str(span)) for span in SPANS} for pid, spans in rollup.items()
    }
    payload["totals"] = {
        "cash_30": round(total_cash_30, 4),
        "subscription_30": round(total_sub_30, 4),
        "all_30": round(total_cash_30 + total_sub_30, 4),
    }

    # Subscriptions declared outside the API (Claude MAX...): attached to the provider of
    # the same name if it exists, otherwise displayed alone.
    for sub in SUBSCRIPTIONS:
        name = (sub.get("name") or "").strip()
        if not name:
            continue
        lowered = name.lower()
        target = next(
            (p for p in payload["providers"] if p["label"].lower() in lowered or lowered.split()[0] in p["label"].lower()),
            None,
        )
        if target:
            target["monthly_usd"] = sub.get("monthly")
            if sub.get("note"):
                target["note"] = sub["note"]
        else:
            payload["providers"].append(
                {
                    "id": prov.normalize(name, ""),
                    "label": name,
                    "kind": "subscription",
                    "color": prov.meta(prov.normalize(name, ""))["color"],
                    "note": sub.get("note") or "subscription outside the API",
                    "balance": None,
                    "burn_30": None,
                    "burn_7": None,
                    "runway_days": None,
                    "history_points": 0,
                    "history_since": None,
                    "windows": {},
                    "month": {"cost": 0.0, "tokens": 0, "calls": 0, "aux_cost": 0.0, "models": 0},
                    "top_model": None,
                    "monthly_usd": sub.get("monthly"),
                    "equivalent_only": True,
                }
            )

    order = {"cash": 0, "subscription": 1, "local": 2, "other": 3}
    payload["providers"].sort(
        key=lambda p: (
            order.get(p["kind"], 9),
            -(p["month"].get("cost") or 0),
        )
    )
    return payload


def refresh() -> None:
    try:
        payload = collect()
    except Exception as exc:  # noqa: BLE001
        payload = {
            "generated_at": _iso(datetime.now(timezone.utc)),
            "status": {},
            "errors": [f"collection: {type(exc).__name__}: {exc}"],
        }
    with _lock:
        _cache["payload"] = payload
        _cache["payload_public"] = public_view(payload)
        _cache["fetched_at"] = time.time()
    if STATE_FILE:
        _write_json(STATE_FILE, payload)


def worker() -> None:
    # Startup cache: display the last valid payload immediately.
    if STATE_FILE and os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, encoding="utf-8") as fh:
                with _lock:
                    _cache["payload"] = json.load(fh)
                    _cache["payload_public"] = public_view(_cache["payload"])
                    _cache["fetched_at"] = 0.0
        except (OSError, json.JSONDecodeError):
            pass
    while True:
        started = time.time()
        refresh()
        elapsed = time.time() - started
        with _lock:
            payload = _cache["payload"] or {}
        bad = [s for s, v in (payload.get("status") or {}).items() if v.get("state") == "error"]
        print(
            f"[usage-dashboard] collected in {elapsed:.1f}s, {len(bad)} source(s) in error"
            + (f" : {', '.join(bad)}" if bad else ""),
            flush=True,
        )
        time.sleep(max(30.0, REFRESH - elapsed))


def page() -> bytes:
    """Serves index.html from the store (re-read if the file changes: handy in testing)."""
    if not PAGE_FILE:
        return b"<h1>usage-dashboard: USAGE_DASHBOARD_PAGE not configured</h1>"
    try:
        mtime = os.path.getmtime(PAGE_FILE)
        with _lock:
            if _page_cache["body"] is not None and _page_cache["mtime"] == mtime:
                return _page_cache["body"]
        with open(PAGE_FILE, "rb") as fh:
            body = fh.read()
        with _lock:
            _page_cache["body"] = body
            _page_cache["mtime"] = mtime
        return body
    except OSError as exc:
        return f"<h1>index.html unreadable: {exc}</h1>".encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "usage-dashboard"
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        # The per-session view brings /api/data to ~325 KB raw (75 KB
        # compressed) and the page reloads it every 60 s: we serve in gzip
        # as soon as the client accepts it, which also matters on a phone.
        encoding = None
        if len(body) >= 1024 and "gzip" in (self.headers.get("Accept-Encoding") or ""):
            packed = gzip.compress(body, 6)
            if len(packed) < len(body):
                body, encoding = packed, "gzip"
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        if encoding:
            self.send_header("Content-Encoding", encoding)
            self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/index.html"):
            self._send(200, page(), "text/html; charset=utf-8")
        elif path == "/api/data":
            trusted = _trusted_client(self.client_address[0])
            with _lock:
                payload = _cache["payload"]
                fetched_at = _cache["fetched_at"]
                if not trusted and _cache["payload_public"] is not None:
                    payload = _cache["payload_public"]
            body = json.dumps(
                {
                    "ok": payload is not None,
                    "age_seconds": round(time.time() - fetched_at, 1) if fetched_at else None,
                    "data": payload,
                },
                ensure_ascii=False,
            ).encode()
            self._send(200, body, "application/json; charset=utf-8")
        elif path == "/healthz":
            with _lock:
                fresh = _cache["payload"] is not None and (time.time() - _cache["fetched_at"]) < max(600.0, REFRESH * 6)
            self._send(200 if fresh else 503, b"ok" if fresh else b"stale", "text/plain")
        else:
            self._send(404, b"not found", "text/plain")

    do_HEAD = do_GET

    def log_message(self, format: str, *args) -> None:  # noqa: A002,A003
        # Silent log: the collection is already logged by the worker.
        return


def main() -> None:
    threading.Thread(target=worker, daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[usage-dashboard] http://{HOST}:{PORT} (refresh {REFRESH:.0f}s)", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
