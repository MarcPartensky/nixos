"""ucpa.marcpartensky.com: UCPA stays search interface.

Goal: answer a question that the UCPA site makes painful. You must choose
a date in a menu to see a price, the displayed prices are season
minima, the formulas (Mini / Half-time / Full-time) are not filterable, and
age is an eligibility criterion hidden in the listing.

Here: a single catalog, all sessions dated with price, spots and departure
status, filtered and sorted on the browser side.

Architecture: a stdlib HTTP server that serves a static page and a JSON.
The catalog is built WITH the MCP server's client (`mcp/modules/ucpa.py`,
imported by path): a single implementation of the UCPA API in the repo.
The catalog is cached on disk per date window (TTL 3 h) and
rebuilt in a background task when it is stale, so a request never blocks
70 s on a UCPA sweep.

Endpoints:
  GET  /                 the page (index.html, next to this file)
  GET  /healthz          health probe for Pangolin
  GET  /api/catalog      catalog (from, to, activities in query, optional)
  GET  /api/meta         cache and last build status
  POST /api/refresh      forces a rebuild (returns immediately, async)

Env: UCPA_MODULE, UCPA_APP_STATE (default /var/lib/ucpa-app), UCPA_APP_HOST,
UCPA_APP_PORT (default 9175), UCPA_APP_TTL (default 10800).
"""

import importlib.util
import json
import os
import threading
import time
import traceback
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
# In Nix, server.py is copied alone into the store: the page is therefore passed via
# UCPA_APP_INDEX (store path), with a fallback on the neighboring file in dev.
INDEX = os.environ.get("UCPA_APP_INDEX") or os.path.join(HERE, "index.html")
MODULE = os.environ.get(
    "UCPA_MODULE", "/home/marc/git/nixos/mcp/modules/ucpa.py"
)
STATE = os.environ.get("UCPA_APP_STATE", "/var/lib/ucpa-app")
HOST = os.environ.get("UCPA_APP_HOST", "0.0.0.0")
PORT = int(os.environ.get("UCPA_APP_PORT", "9175"))
TTL = float(os.environ.get("UCPA_APP_TTL", "10800"))
WORKERS = int(os.environ.get("UCPA_APP_WORKERS", "6"))

DEFAULT_FROM = "2027-02-01"
DEFAULT_TO = "2027-02-28"
DEFAULT_ACTIVITIES = "ski"

os.makedirs(STATE, exist_ok=True)

_lock = threading.Lock()
_building = set()
_status = {}


def _load_client():
    spec = importlib.util.spec_from_file_location("ucpa_client", MODULE)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"UCPA module not found: {MODULE}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ucpa = _load_client()


# ----------------------------------------------------------------- vocabulary

FORMULAS = [
    ("mini", "Mini", "no lessons"),
    ("mi-temps", "Half-time", "12 h of lessons"),
    ("plein-temps", "Full-time", "23 h of lessons"),
    ("decouverte", "Discovery", "intro"),
    ("apprendre", "Learn", "beginner lessons"),
    ("hors-piste", "Off-piste", "guided off-piste"),
    ("rando", "Touring", "climbing skins"),
    ("nordique", "Nordic", "cross-country skiing"),
    ("autre", "Other", ""),
]


def _formula(name):
    low = name.lower()
    if "plein-temps" in low or "plein temps" in low:
        return "plein-temps"
    if "mi-temps" in low or "mi temps" in low:
        return "mi-temps"
    if "pack mini" in low:
        return "mini"
    if "découverte" in low or "decouverte" in low:
        return "decouverte"
    if "apprendre" in low:
        return "apprendre"
    if "hors-piste" in low or "hors piste" in low:
        return "hors-piste"
    if "rando" in low:
        return "rando"
    if "nordique" in low or "skating" in low or "fond" in low:
        return "nordique"
    return "autre"


def _family(activity, name):
    low = (activity or "").lower()
    if "snowboard" in low or "splitboard" in low:
        return "snowboard"
    if "nordique" in low or "skating" in low:
        return "nordique"
    if "rando" in low:
        return "rando"
    if "biathlon" in low:
        return "biathlon"
    if "raquette" in low:
        return "raquettes"
    return "ski"


def _image_url(path, width=240):
    """Relative path returned by the UCPA image CDN, or None."""
    if not path:
        return None
    if path.startswith("http"):
        return path
    if not path.startswith("/"):
        path = "/" + path
    return f"https://media.ucpa.com/image/upload/f_auto,w_{width}{path}"


def _key(date_from, date_to, activities):
    return f"{date_from}_{date_to}_{activities}".replace("/", "-")


def _catalog_path(key):
    return os.path.join(STATE, f"catalog-{key}.json")


def _load_cached(key):
    try:
        with open(_catalog_path(key), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------- build


def _build(key, date_from, date_to, activities):
    """Full UCPA sweep: one entry per stay, all its sessions."""
    started = time.time()
    filters = ucpa._build_filters(activities, date_from, date_to)
    total, products = ucpa._collect(filters, sortby="prix_sort_asc", max_items=5000)
    rows = []
    failures = []

    def work(entry):
        try:
            detail = ucpa._detail(entry["uuid"])
        except Exception as exc:  # noqa: BLE001 (a failing stay does not block)
            failures.append({"uuid": entry["uuid"], "error": str(exc)[:160]})
            return None
        sessions = ucpa._sessions_from(detail, date_from, date_to)
        sans = [s for s in sessions if not s["transport"]]
        avec = [s for s in sessions if s["transport"]]
        if not sans and not avec:
            return None
        by_date = {}
        for sess in sans:
            cur = by_date.get(sess["date"])
            if cur is None or (sess["price"] or 0) < (cur["price"] or 0):
                by_date[sess["date"]] = sess
        dates = [by_date[d] for d in sorted(by_date)]
        trans = {}
        for sess in avec:
            cur = trans.get(sess["date"])
            if cur is None or (sess["price"] or 0) < (cur["price"] or 0):
                trans[sess["date"]] = {
                    "price": sess["price"],
                    "city": sess["departure_city"],
                }
        prices = [s["price"] for s in dates if s["price"]]
        nights = sorted({s["nights"] for s in dates if s["nights"]})
        cheapest = min(dates, key=lambda s: s["price"] or 10**9) if dates else None
        available = [s for s in dates if s.get("available") and (s.get("stock") or 0) > 0]
        return {
            "uuid": entry["uuid"],
            "name": entry["name"],
            "center": entry["center"],
            "country": entry["country"],
            "activity": entry["activity"],
            "activity_name": entry["activity_name"],
            "family": _family(entry["activity"], entry["name"]),
            "formula": _formula(entry["name"]),
            "age_min": entry["age_min"],
            "age_max": entry["age_max"],
            "level": entry["level"],
            "nights": nights,
            "url": entry["url"],
            "image": _image_url(entry.get("image")),
            "price_min": min(prices) if prices else None,
            "price_max": max(prices) if prices else None,
            "price_per_night": round(min(prices) / cheapest["nights"], 2)
            if prices and cheapest and cheapest["nights"]
            else None,
            "next_date": cheapest["date"] if cheapest else None,
            "next_price": cheapest["price"] if cheapest else None,
            "sessions_open": len(available),
            "guaranteed": any(
                (s.get("guaranteed") or "").lower().startswith("départ garanti")
                for s in dates
            ),
            "sessions": [
                {
                    "date": s["date"],
                    "nights": s["nights"],
                    "days": s["days"],
                    "price": s["price"],
                    "before": s["price_before"],
                    "stock": s["stock"],
                    "capacity": s["capacity"],
                    "available": bool(s["available"]),
                    "guaranteed": s["guaranteed"],
                    "transport": trans.get(s["date"], {}).get("price"),
                    "transport_city": trans.get(s["date"], {}).get("city"),
                }
                for s in dates
            ],
        }

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for row in pool.map(work, products):
            if row:
                rows.append(row)
    rows.sort(key=lambda r: r["price_min"] or 10**9)
    payload = {
        "generated_at": int(time.time()),
        "build_seconds": round(time.time() - started, 1),
        "query": {
            "date_from": date_from,
            "date_to": date_to,
            "activities": ucpa._slug_list(activities),
        },
        "offers_matched": total,
        "products_scanned": len(products),
        "products": len(rows),
        "failures": failures[:5],
        "formulas": [{"key": k, "label": l, "hint": h} for k, l, h in FORMULAS],
        "families": sorted({r["family"] for r in rows}),
        "rows": rows,
    }
    with open(_catalog_path(key) + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.replace(_catalog_path(key) + ".tmp", _catalog_path(key))
    return payload


def _refresh_async(key, date_from, date_to, activities):
    if key in _building:
        return

    def run():
        with _lock:
            if key in _building:
                return
            _building.add(key)
        try:
            payload = _build(key, date_from, date_to, activities)
            _status[key] = {
                "ok": True,
                "at": payload["generated_at"],
                "products": payload["products"],
            }
        except Exception as exc:  # noqa: BLE001
            _status[key] = {
                "ok": False,
                "error": str(exc)[:300],
                "trace": traceback.format_exc()[-800:],
            }
        finally:
            _building.discard(key)

    threading.Thread(target=run, daemon=True).start()


def get_catalog(date_from, date_to, activities, force=False):
    key = _key(date_from, date_to, activities)
    cached = _load_cached(key)
    stale = cached is None or (time.time() - cached.get("generated_at", 0)) > TTL
    if (force or stale) and key not in _building:
        _refresh_async(key, date_from, date_to, activities)
    return key, cached, stale


# ------------------------------------------------------------------ server


class Handler(BaseHTTPRequestHandler):
    server_version = "ucpa-app/1.0"

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _query(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        get = lambda k, d="": (params.get(k) or [d])[0].strip()  # noqa: E731
        return parsed.path, get

    def do_GET(self):  # noqa: N802
        path, get = self._query()
        if path == "/healthz":
            return self._send(200, json.dumps({"ok": True}), "application/json")
        if path in ("/", "/index.html"):
            with open(INDEX, "rb") as fh:
                return self._send(200, fh.read(), "text/html; charset=utf-8")
        if path == "/api/meta":
            key, cached, stale = get_catalog(
                get("from", DEFAULT_FROM), get("to", DEFAULT_TO),
                get("activities", DEFAULT_ACTIVITIES),
            )
            return self._send(
                200,
                json.dumps(
                    {
                        "key": key,
                        "cached": bool(cached),
                        "stale": stale,
                        "building": key in _building,
                        "generated_at": (cached or {}).get("generated_at"),
                        "products": (cached or {}).get("products"),
                        "build_seconds": (cached or {}).get("build_seconds"),
                        "last_status": _status.get(key),
                    },
                    ensure_ascii=False,
                ),
            )
        if path == "/api/catalog":
            key, cached, stale = get_catalog(
                get("from", DEFAULT_FROM), get("to", DEFAULT_TO),
                get("activities", DEFAULT_ACTIVITIES),
            )
            if cached is None:
                return self._send(
                    202,
                    json.dumps(
                        {
                            "building": True,
                            "key": key,
                            "message": "first UCPA sweep in progress",
                        }
                    ),
                )
            payload = dict(cached)
            payload["stale"] = stale
            payload["building"] = key in _building
            return self._send(200, json.dumps(payload, ensure_ascii=False))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):  # noqa: N802
        path, get = self._query()
        if path == "/api/refresh":
            key, _cached, _stale = get_catalog(
                get("from", DEFAULT_FROM), get("to", DEFAULT_TO),
                get("activities", DEFAULT_ACTIVITIES), force=True,
            )
            return self._send(202, json.dumps({"refreshing": key}))
        return self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, format, *args):  # noqa: A002, N802
        return


def main():
    # First startup: if no catalog exists, we build it in a
    # background task right away, the page shows the wait.
    get_catalog(DEFAULT_FROM, DEFAULT_TO, DEFAULT_ACTIVITIES)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"ucpa-app on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
