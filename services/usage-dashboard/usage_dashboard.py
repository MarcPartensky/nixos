#!/usr/bin/env python3
"""Dashboard d'usage LLM (OpenRouter + providers directs) pour tower.

Ce que le service lit, jamais n'ecrit (sauf le dernier payload valide, pour
que la page ne soit pas vide apres un redemarrage) :

  - OpenRouter /api/v1/credits          : credits achetes / consommes / restants
  - OpenRouter /api/v1/analytics/meta   : metriques et dimensions reellement
                                          disponibles (le schema bouge, on ne le
                                          suppose pas)
  - OpenRouter /api/v1/analytics/query  : depense par modele, par cle d'API et
                                          par jour (fenetre 30 jours)
  - OpenRouter /api/v1/key              : usage temps reel jour/semaine/mois de
                                          la cle d'inference
  - Moonshot /v1/users/me/balance       : solde du provider kimi direct
  - DeepSeek /user/balance              : solde du provider deepseek direct
                                          (seul endpoint de facturation qu'une cle
                                          API DeepSeek peut lire : total, offert,
                                          recharge. Le detail par cle/jour n'existe
                                          que sur la console, derriere un login)
  - frankfurter.dev                     : taux USD->EUR et USD->CNY (BCE, sans cle)

Deux cles OpenRouter, deux roles : la cle d'INFERENCE donne l'usage temps reel
de cette cle ; la cle MANAGEMENT (Settings > Management Keys) est la seule a
ouvrir /analytics, donc la seule a donner le detail par modele. Elle ne peut
pas faire d'inference : lecture seule, gratuite. Sans elle, la page affiche le
solde et le temps reel, et le dit dans son bandeau d'etat.

Aucune dependance hors stdlib. La page est servie statique et interroge
/api/data : le rafraichissement est cote navigateur, donc une page ouverte
reste a jour sans redeploiement.
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("USAGE_DASHBOARD_HOST", "0.0.0.0")
PORT = int(os.environ.get("USAGE_DASHBOARD_PORT", "9141"))
PAGE_FILE = os.environ.get("USAGE_DASHBOARD_PAGE", "")
STATE_FILE = os.environ.get("USAGE_DASHBOARD_STATE", "")
MGMT_KEY_FILE = os.environ.get("USAGE_DASHBOARD_MANAGEMENT_KEY_FILE", "")
INFER_KEY_FILE = os.environ.get("USAGE_DASHBOARD_INFERENCE_KEY_FILE", "")
MOONSHOT_KEY_FILE = os.environ.get("USAGE_DASHBOARD_MOONSHOT_KEY_FILE", "")
DEEPSEEK_KEY_FILE = os.environ.get("USAGE_DASHBOARD_DEEPSEEK_KEY_FILE", "")
REFRESH = float(os.environ.get("USAGE_DASHBOARD_REFRESH", "120"))
WINDOW_DAYS = int(os.environ.get("USAGE_DASHBOARD_WINDOW_DAYS", "30"))
SUBSCRIPTIONS = json.loads(os.environ.get("USAGE_DASHBOARD_SUBSCRIPTIONS", "[]") or "[]")

OR_API = "https://openrouter.ai/api/v1"
MOONSHOT_API = "https://api.moonshot.ai/v1"
DEEPSEEK_API = "https://api.deepseek.com"
FX_URL = "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR,CNY"

# Jamais le nom de marc dans un User-Agent.
UA = "hermes-research/1.0"

# Familles affichees : prefixe du slug de modele -> (libelle, couleur).
FAMILIES = {
    "deepseek": ("DeepSeek", "#89b4fa"),
    "anthropic": ("Claude", "#fab387"),
    "moonshotai": ("Kimi", "#cba6f7"),
    "moonshot": ("Kimi", "#cba6f7"),
    "openai": ("ChatGPT", "#a6e3a1"),
    "google": ("Gemini", "#74c7ec"),
    "x-ai": ("Grok", "#f9e2af"),
    "qwen": ("Qwen", "#94e2d5"),
    "meta-llama": ("Llama", "#f5c2e7"),
    "mistralai": ("Mistral", "#eba0ac"),
    "nvidia": ("Nvidia", "#b4befe"),
    "z-ai": ("Z.ai", "#89dceb"),
    "minimax": ("MiniMax", "#f2cdcd"),
    "amazon": ("Amazon", "#f5e0dc"),
    "cohere": ("Cohere", "#f38ba8"),
}
FALLBACK_COLORS = ["#b4befe", "#89b4fa", "#94e2d5", "#f9e2af", "#fab387", "#f5c2e7", "#eba0ac", "#74c7ec"]

_lock = threading.Lock()
_cache: dict = {"payload": None, "fetched_at": 0.0}
_page_cache: dict = {"body": None, "mtime": 0.0}


# --------------------------------------------------------------------------
# bas niveau
# --------------------------------------------------------------------------
def _read_secret(path: str) -> str | None:
    """Lit un secret d'un fichier. Un placeholder non remplace vaut absent."""
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return None
    if not value or value.upper().startswith("PLACEHOLDER"):
        return None
    return value


def _http(url: str, key: str | None = None, payload: dict | None = None, timeout: int = 25):
    """Renvoie (data, None) ou (None, message d'erreur lisible)."""
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
    """Les compteurs de l'API arrivent en nombre OU en chaine : accepter les deux."""
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


def family_of(model: str) -> tuple[str, str, str]:
    """(cle, libelle, couleur) d'une famille a partir du slug de modele."""
    prefix = (model or "inconnu").split("/")[0].lower()
    if prefix in FAMILIES:
        label, color = FAMILIES[prefix]
        return prefix, label, color
    index = sum(ord(c) for c in prefix) % len(FALLBACK_COLORS)
    return prefix, prefix, FALLBACK_COLORS[index]


# --------------------------------------------------------------------------
# collecte
# --------------------------------------------------------------------------
def collect() -> dict:
    now = datetime.now(timezone.utc)
    payload: dict = {
        "generated_at": _iso(now),
        "status": {},
        "errors": [],
        "window_days": WINDOW_DAYS,
        "fx": None,
        "account": None,
        "realtime": None,
        "windows": {},
        "by_model": [],
        "by_family": [],
        "daily": [],
        "by_key": [],
        "other_providers": [],
        "subscriptions": SUBSCRIPTIONS,
        "meta": None,
    }

    def note(source: str, state: str, message: str | None = None) -> None:
        payload["status"][source] = {"state": state, "message": message}
        if state != "ok":
            payload["errors"].append(f"{source}: {message}")

    mgmt = _read_secret(MGMT_KEY_FILE)
    infer = _read_secret(INFER_KEY_FILE)

    # 1. Solde du compte. /credits repond aussi a une cle d'inference, donc on
    #    prend la premiere cle disponible : le solde ne depend pas du role.
    credits_key = mgmt or infer
    if credits_key:
        data, err = _http(f"{OR_API}/credits", key=credits_key)
        if err:
            note("openrouter/credits", "error", err)
        else:
            info = (data or {}).get("data") or {}
            total = _num(info.get("total_credits"))
            used = _num(info.get("total_usage"))
            payload["account"] = {
                "total_credits": total,
                "total_usage": used,
                "remaining": round(total - used, 6),
                "used_pct": round(100.0 * used / total, 2) if total > 0 else 0.0,
            }
            note("openrouter/credits", "ok")
    else:
        note("openrouter/credits", "missing", "aucune cle OpenRouter lisible")

    # 2. Usage temps reel de la cle d'inference (jour/semaine/mois).
    if infer:
        data, err = _http(f"{OR_API}/key", key=infer)
        if err:
            note("openrouter/key", "error", err)
        else:
            info = (data or {}).get("data") or {}
            payload["realtime"] = {
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
        note("openrouter/key", "missing", "cle d'inference absente (usage temps reel indisponible)")

    # 3. Taux de change (sans cle, purement cosmetique : un echec ne casse rien).
    data, err = _http(FX_URL, timeout=12)
    if err:
        note("frankfurter", "error", err)
    else:
        rates = (data or {}).get("rates") or {}
        if rates.get("EUR"):
            payload["fx"] = {
                "usd_eur": _num(rates["EUR"]),
                "usd_cny": _num(rates["CNY"]) or None,
                "date": (data or {}).get("date"),
            }
            note("frankfurter", "ok")
        else:
            note("frankfurter", "error", "pas de taux EUR dans la reponse")

    # 4. Moonshot (provider kimi direct, hors OpenRouter).
    moonshot = _read_secret(MOONSHOT_KEY_FILE)
    if moonshot:
        data, err = _http(f"{MOONSHOT_API}/users/me/balance", key=moonshot, timeout=15)
        if err:
            note("moonshot", "error", err)
        else:
            info = (data or {}).get("data") or {}
            payload["other_providers"].append(
                {
                    "name": "Moonshot (kimi direct)",
                    "kind": "balance",
                    "currency": "USD",
                    "available": _num(info.get("available_balance")),
                    "voucher": _num(info.get("voucher_balance")),
                    "cash": _num(info.get("cash_balance")),
                }
            )
            note("moonshot", "ok")
    else:
        note("moonshot", "missing", "cle Moonshot absente (kimi direct non suivi)")

    # 4b. DeepSeek direct : une cle API ne peut lire QUE le solde (verifie dans
    #     leurs docs : /user/usage, /user/billing, /dashboard/billing/usage sont
    #     en 404). Le detail par cle/jour n'existe que sur la console, derriere
    #     une session de navigateur. La devise peut etre CNY ou USD.
    deepseek = _read_secret(DEEPSEEK_KEY_FILE)
    if deepseek:
        data, err = _http(f"{DEEPSEEK_API}/user/balance", key=deepseek, timeout=15)
        if err:
            note("deepseek", "error", err)
        else:
            infos = (data or {}).get("balance_infos") or []
            info = infos[0] if infos else {}
            payload["other_providers"].append(
                {
                    "name": "DeepSeek (direct)",
                    "kind": "balance",
                    "currency": info.get("currency") or "USD",
                    "available": _num(info.get("total_balance")),
                    "granted": _num(info.get("granted_balance")),
                    "topped_up": _num(info.get("topped_up_balance")),
                    "usable": bool((data or {}).get("is_available")),
                    "all": [
                        {
                            "currency": i.get("currency"),
                            "total": _num(i.get("total_balance")),
                            "granted": _num(i.get("granted_balance")),
                            "topped_up": _num(i.get("topped_up_balance")),
                        }
                        for i in infos
                    ],
                }
            )
            note("deepseek", "ok")
    else:
        note("deepseek", "missing", "cle DeepSeek absente (compte direct non suivi)")

    # 5. Analytics : le coeur du dashboard, cle management obligatoire.
    if not mgmt:
        note(
            "openrouter/analytics",
            "missing",
            "cle management absente : pas de detail par modele (Settings > Management Keys)",
        )
        return payload

    meta, err = _http(f"{OR_API}/analytics/meta", key=mgmt)
    metrics: set[str] = set()
    if err:
        note("openrouter/analytics/meta", "error", err)
    else:
        data = (meta or {}).get("data") or {}
        metrics = {m.get("name") for m in (data.get("metrics") or []) if m.get("name")}
        payload["meta"] = {
            "metrics": sorted(metrics),
            "dimensions": sorted(
                d.get("name") for d in (data.get("dimensions") or []) if d.get("name")
            ),
            "granularities": sorted(
                g.get("name") for g in (data.get("granularities") or []) if g.get("name")
            ),
        }
        note("openrouter/analytics/meta", "ok")

    def ask(metrics_wanted: list[str], dimensions: list[str] | None = None, start=None, end=None,
            granularity: str | None = None, limit: int = 100, order: str | None = None):
        """Requete analytics filtree sur les metriques reellement disponibles."""
        usable = [m for m in metrics_wanted if not metrics or m in metrics]
        if "total_usage" not in usable:
            usable.insert(0, "total_usage")
        body: dict = {
            "metrics": usable,
            "time_range": {"start": _iso(start or (now - timedelta(days=WINDOW_DAYS))), "end": _iso(end or now)},
            "limit": limit,
        }
        if dimensions:
            body["dimensions"] = dimensions
        if granularity:
            body["granularity"] = granularity
        if order:
            body["order_by"] = {"field": order, "direction": "desc"}
        data, error = _http(f"{OR_API}/analytics/query", key=mgmt, payload=body)
        if error:
            return [], error
        rows = ((data or {}).get("data") or {}).get("data") or []
        truncated = ((data or {}).get("data") or {}).get("metadata", {}).get("truncated")
        return rows, ("truncated" if truncated else None)

    # 5a. Totaux par fenetre.
    windows = {
        "today": now.replace(hour=0, minute=0, second=0, microsecond=0),
        "week": now - timedelta(days=7),
        "month": now - timedelta(days=WINDOW_DAYS),
    }
    for name, start in windows.items():
        rows, err = ask(["total_usage", "request_count", "tokens_total"], start=start, limit=1)
        if err and err != "truncated":
            note(f"openrouter/analytics/{name}", "error", err)
            continue
        row = rows[0] if rows else {}
        payload["windows"][name] = {
            "start": _iso(start),
            "usage": _num(row.get("total_usage")),
            "requests": _num(row.get("request_count")),
            "tokens": _num(row.get("tokens_total")),
        }
        note(f"openrouter/analytics/{name}", "ok")

    # 5b. Depense par modele sur la fenetre.
    rows, err = ask(
        [
            "total_usage",
            "request_count",
            "tokens_total",
            "tokens_prompt",
            "tokens_completion",
            "reasoning_tokens",
            "cache_hit_rate",
        ],
        dimensions=["model"],
        limit=200,
        order="total_usage",
    )
    if err and err != "truncated":
        note("openrouter/analytics/by_model", "error", err)
    else:
        models = []
        for row in rows:
            model = row.get("model") or "inconnu"
            key, label, color = family_of(model)
            usage = _num(row.get("total_usage"))
            tokens = _num(row.get("tokens_total"))
            models.append(
                {
                    "model": model,
                    "family": key,
                    "family_label": label,
                    "color": color,
                    "usage": usage,
                    "requests": _num(row.get("request_count")),
                    "tokens": tokens,
                    "tokens_prompt": _num(row.get("tokens_prompt")),
                    "tokens_completion": _num(row.get("tokens_completion")),
                    "reasoning_tokens": _num(row.get("reasoning_tokens")),
                    "cache_hit_rate": _num(row.get("cache_hit_rate")),
                    "usd_per_mtok": round(usage / tokens * 1e6, 4) if tokens > 0 else None,
                }
            )
        models.sort(key=lambda m: m["usage"], reverse=True)
        payload["by_model"] = models
        grouped: dict[str, dict] = {}
        for model in models:
            entry = grouped.setdefault(
                model["family"],
                {
                    "family": model["family"],
                    "label": model["family_label"],
                    "color": model["color"],
                    "usage": 0.0,
                    "requests": 0.0,
                    "tokens": 0.0,
                    "models": 0,
                },
            )
            entry["usage"] += model["usage"]
            entry["requests"] += model["requests"]
            entry["tokens"] += model["tokens"]
            entry["models"] += 1
        payload["by_family"] = sorted(grouped.values(), key=lambda f: f["usage"], reverse=True)
        note("openrouter/analytics/by_model", "ok" + (" (tronque)" if err == "truncated" else ""))

    # 5c. Serie quotidienne.
    rows, err = ask(
        ["total_usage", "request_count", "tokens_total"], granularity="day", limit=400
    )
    if err and err != "truncated":
        note("openrouter/analytics/daily", "error", err)
    else:
        by_date: dict[str, dict] = {}
        for row in rows:
            date = next((str(v) for k, v in row.items() if k.startswith("date__")), None)
            if not date:
                continue
            entry = by_date.setdefault(
                date[:10], {"date": date[:10], "usage": 0.0, "requests": 0.0, "tokens": 0.0, "families": {}}
            )
            usage = _num(row.get("total_usage"))
            entry["usage"] += usage
            entry["requests"] += _num(row.get("request_count"))
            entry["tokens"] += _num(row.get("tokens_total"))
        payload["daily"] = [by_date[d] for d in sorted(by_date)]
        note("openrouter/analytics/daily", "ok")

    # 5d. Serie quotidienne par famille (modele en dimension + axe jour) : sert
    #     au graphique empile. Deux dimensions max cote API, on reste a une.
    rows, err = ask(["total_usage"], dimensions=["model"], granularity="day", limit=1000)
    if err and err != "truncated":
        note("openrouter/analytics/daily_family", "error", err)
    else:
        by_date = {d["date"]: d for d in payload["daily"]}
        for row in rows:
            date = next((str(v) for k, v in row.items() if k.startswith("date__")), None)
            model = row.get("model") or "inconnu"
            if not date:
                continue
            entry = by_date.setdefault(
                date[:10], {"date": date[:10], "usage": 0.0, "requests": 0.0, "tokens": 0.0, "families": {}}
            )
            key, label, color = family_of(model)
            slot = entry["families"].setdefault(key, {"label": label, "color": color, "usage": 0.0})
            slot["usage"] += _num(row.get("total_usage"))
        payload["daily"] = [by_date[d] for d in sorted(by_date)]
        note("openrouter/analytics/daily_family", "ok")

    # 5e. Depense par cle d'API : dit quel pipeline (hermes, cron, windmill...)
    #     consomme quoi.
    rows, err = ask(
        ["total_usage", "request_count", "tokens_total"],
        dimensions=["api_key_id"],
        limit=50,
        order="total_usage",
    )
    if err and err != "truncated":
        note("openrouter/analytics/by_key", "error", err)
    else:
        payload["by_key"] = [
            {
                "key": row.get("api_key_id") or "inconnue",
                "usage": _num(row.get("total_usage")),
                "requests": _num(row.get("request_count")),
                "tokens": _num(row.get("tokens_total")),
            }
            for row in rows
        ]
        note("openrouter/analytics/by_key", "ok")

    return payload


def refresh() -> None:
    try:
        payload = collect()
    except Exception as exc:  # noqa: BLE001
        payload = {"generated_at": _iso(datetime.now(timezone.utc)), "status": {}, "errors": [f"collecte: {exc}"]}
    with _lock:
        _cache["payload"] = payload
        _cache["fetched_at"] = time.time()
    if STATE_FILE:
        try:
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(payload, fh)
            os.replace(tmp, STATE_FILE)
        except OSError as exc:
            print(f"[usage-dashboard] ecriture de l'etat impossible : {exc}", flush=True)


def worker() -> None:
    # Cache de demarrage : afficher tout de suite le dernier payload valide.
    if STATE_FILE and os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, encoding="utf-8") as fh:
                with _lock:
                    _cache["payload"] = json.load(fh)
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
            f"[usage-dashboard] collecte en {elapsed:.1f}s, {len(bad)} source(s) en erreur"
            + (f" : {', '.join(bad)}" if bad else ""),
            flush=True,
        )
        time.sleep(max(30.0, REFRESH - elapsed))


def page() -> bytes:
    """Sert index.html depuis le store (relu si le fichier change : pratique en test)."""
    if not PAGE_FILE:
        return b"<h1>usage-dashboard : USAGE_DASHBOARD_PAGE non configure</h1>"
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
        return f"<h1>index.html illisible : {exc}</h1>".encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "usage-dashboard"
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
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
            with _lock:
                payload = _cache["payload"]
                fetched_at = _cache["fetched_at"]
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
        # Journal silencieux : la collecte est deja journalisee par le worker.
        return


def main() -> None:
    threading.Thread(target=worker, daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[usage-dashboard] http://{HOST}:{PORT} (rafraichissement {REFRESH:.0f}s)", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
