"""UCPA tools (ski/snowboard stays, prices, watch) for mcp-host.

Why this module rather than a dedicated MCP server: ucpa.com exposes no
documented API, but its AMP/Vue front end queries two public JSON routes,
with no account or key:

  GET /api/products?filters=<json>&start=&limit=&sortby=
      Discovery. Returns one entry per offer/session, with the product
      (uuid, name, center, activity, age min/max, url) and an indicative price
      named price_from here: this is NOT the price of a dated session (measurement
      of 18/11/2026: 693 in the list versus 1140 in the detail for the same stay).
  GET /api/product/<uuid>?locale=fr&workspace=ucpa
      Ground truth. offersInfo carries the sessions with the full date
      (dF, DD/MM/YYYY), price, stock, guaranteed departure status, and for each
      session the variants with transport (departC = departure city).
      ~930 KB uncompressed, 23 KB gzip, ~2 s: we cache to disk.

Filters verified on the API (a filter that is not honored would return 200 +
identical body): activity_label, date_start_min, date_start_max (DD/MM/YYYY),
availability=[1], age_list, transport_departure_city, month, season, country,
segment_marketing, price_range, duration. Negative control: February 2019
returns 0 results, so the date window does filter correctly.

AGE: UCPA does not bill by age on these stays. Age is an
ELIGIBILITY criterion (product_age_min/max, and the API's age_list filter). A
"18-40 years" stay is therefore open at 26, a "14-17" one is not.

Cache and watch: everything lives in UCPA_STATE_DIR (default
~/.local/state/ucpa-mcp). The cache avoids hammering a site that takes 2 to 7 s
per request; the watch keeps the last GOOD reading per session and never
overwrites it with an errored reading.

Env: UCPA_BASE, UCPA_STATE_DIR, UCPA_TIMEOUT (default 60),
UCPA_CACHE_TTL (seconds, default 3600), UCPA_MAX_WORKERS (default 6).
"""

import gzip
import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

try:
    from fastmcp.tools import tool
except Exception:  # test outside mcp-host: neutral decorator

    def tool(fn=None, **_kw):
        if fn is not None:
            return fn
        return lambda f: f


BASE = os.environ.get("UCPA_BASE", "https://www.ucpa.com").rstrip("/")
STATE_DIR = os.environ.get(
    "UCPA_STATE_DIR",
    os.path.join(os.path.expanduser("~"), ".local", "state", "ucpa-mcp"),
)
CACHE_DIR = os.path.join(STATE_DIR, "cache")
WATCH_FILE = os.path.join(STATE_DIR, "watches.json")
TIMEOUT = float(os.environ.get("UCPA_TIMEOUT", "60"))
CACHE_TTL = float(os.environ.get("UCPA_CACHE_TTL", "3600"))
WORKERS = max(1, int(os.environ.get("UCPA_MAX_WORKERS", "6")))
WORKSPACE = os.environ.get("UCPA_WORKSPACE", "ucpa")

# The site is behind an AMP anti-bot: a full browser UA is
# necessary, a short UA gets rejected. No username inside.
UA = os.environ.get(
    "UCPA_UA",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36",
)

# Activity families as named by UCPA's activity_label facet.
SKI_SNOWBOARD = [
    "ski-alpin",
    "ski-alpin-ou-snowboard",
    "ski-hors-piste",
    "ski-de-randonnee",
    "ski-freestyle",
    "ski-nordique",
    "snowboard",
    "snowboard-freestyle",
    "snowboard-hors-piste",
    "splitboard",
    "snowkite",
]

DEFAULT_FROM = "2027-02-01"
DEFAULT_TO = "2027-02-28"

_lock = threading.Lock()


# ------------------------------------------------------------------ network


def _resolve_dir(path):
    os.makedirs(path, exist_ok=True)
    return path


def _cache_path(kind, key):
    _resolve_dir(CACHE_DIR)
    digest = hashlib.sha1(key.encode()).hexdigest()[:16]
    return os.path.join(CACHE_DIR, f"{kind}-{digest}.json")


def _cache_get(kind, key, ttl):
    path = _cache_path(kind, key)
    try:
        if ttl >= 0 and time.time() - os.path.getmtime(path) > ttl:
            return None
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _cache_put(kind, key, payload):
    path = _cache_path(kind, key)
    tmp = path + ".tmp"
    with _lock:
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(payload, fh)
            os.replace(tmp, path)
        except OSError:
            pass


def _fetch(path, params=None, ttl=None):
    """GET JSON with disk cache. Raises RuntimeError with the raw body."""
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    ttl = CACHE_TTL if ttl is None else ttl
    cached = _cache_get("json", url, ttl)
    if cached is not None:
        return cached
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            payload = json.loads(raw)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise RuntimeError(f"UCPA HTTP {exc.code} on {path}: {detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"UCPA unreachable ({path}): {exc.reason}") from None
    except ValueError:
        raise RuntimeError(f"UCPA {path}: non-JSON response") from None
    _cache_put("json", url, payload)
    return payload


# ------------------------------------------------------------- conversions


def _iso(fr_date):
    """'07/02/2027' -> '2027-02-07'. Returns None if the format is unexpected."""
    try:
        day, month, year = str(fr_date).split("/")
        return f"{year}-{month}-{day}"
    except (ValueError, AttributeError):
        return None


def _fr(iso_date):
    """'2027-02-01' -> '01/02/2027' (format expected by the filter API)."""
    parts = str(iso_date).split("-")
    if len(parts) != 3:
        raise RuntimeError(f"date expected as YYYY-MM-DD, got {iso_date!r}")
    return f"{parts[2]}/{parts[1]}/{parts[0]}"


def _num(value, digits=2):
    try:
        return round(float(value), digits)
    except (TypeError, ValueError):
        return None


def _slug_list(activities):
    """Resolves the aliases ('ski', 'tous') into UCPA activity_label slugs."""
    if activities is None:
        return list(SKI_SNOWBOARD)
    if isinstance(activities, str):
        text = activities.strip().lower()
        if text in ("", "all", "tous", "*"):
            return []
        if text in ("ski", "neige", "ski-snowboard", "snow"):
            return list(SKI_SNOWBOARD)
        return [v.strip() for v in activities.split(",") if v.strip()]
    return [str(v).strip() for v in activities if str(v).strip()]


def _build_filters(
    activities,
    date_from,
    date_to,
    age=None,
    departure_city=None,
    max_price=None,
    duration=None,
):
    filters = {}
    slugs = _slug_list(activities)
    if slugs:
        filters["activity_label"] = slugs
    if date_from:
        filters["date_start_min"] = [_fr(date_from)]
    if date_to:
        filters["date_start_max"] = [_fr(date_to)]
    if date_from or date_to:
        # Excludes stays with no room in the window. Verified: without this
        # pair, the API also returns non-bookable products.
        filters["availability"] = [1]
    if age is not None:
        filters["age_list"] = [int(age)]
    if departure_city:
        filters["transport_departure_city"] = [departure_city]
    if duration:
        filters["duration"] = [duration]
    return filters


# --------------------------------------------------------------- API reading


def _search_page(filters, start, limit, sortby, ttl, query=None):
    params = {
        "filters": json.dumps(filters, separators=(",", ":"), ensure_ascii=False),
        "start": int(start),
        "limit": int(limit),
    }
    if query:
        params["query"] = query
    if sortby and sortby != "pertinence":
        params["sortby"] = sortby
    data = _fetch("/api/products", params, ttl=ttl)
    return data.get("productsGlobalSearch") or {}


def _collect(filters, sortby="pertinence", max_items=600, ttl=None, limit=100):
    """Paginates the discovery and returns (total, sorted unique products).

    The pages are independent: they run in parallel (6 by default).
    Without that, a ski/snowboard sweep of February 2027 costs 68 s end to
    end, the API answering in 5 s per page of 100 offers.
    """
    total = None
    items = []
    start = 0
    while True:
        page = _search_page(filters, start, limit, sortby, ttl)
        if total is None:
            total = page.get("count") or 0
        chunk = page.get("items") or []
        if not chunk:
            break
        items.extend(chunk)
        start += len(chunk)
        if start >= min(total, max_items) or len(chunk) < limit:
            break
    ends = min(total or start, max_items)
    starts = list(range(start, ends, limit))
    if starts:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for chunk in pool.map(
                lambda s: _search_page(filters, s, limit, sortby, ttl).get("items")
                or [],
                starts,
            ):
                items.extend(chunk)
    products = {}
    for item in items:
        uuid = item.get("uuid")
        if not uuid:
            continue
        price = _num(item.get("price"))
        entry = products.get(uuid)
        if entry is None:
            entry = {
                "uuid": uuid,
                "name": item.get("product_name"),
                "center": item.get("center_or_destination_name"),
                "activity": item.get("activity_label"),
                "activity_name": item.get("activity_name"),
                "age_min": item.get("product_age_min"),
                "age_max": item.get("product_age_max"),
                "duration_days": item.get("product_days_duration_including_transportation"),
                "nights": item.get("product_nights_duration"),
                "level": item.get("expertise_level"),
                "url": "https://www.ucpa.com" + (item.get("url") or ""),
                "image": item.get("product_main_image"),
                "price_from": price,
                "discount_pct": item.get("discount_percentage"),
                "country": item.get("country"),
            }
            products[uuid] = entry
        elif price is not None:
            if entry["price_from"] is None or price < entry["price_from"]:
                entry["price_from"] = price
    rows = list(products.values())
    if sortby == "prix_sort_desc":
        rows.sort(key=lambda r: r["price_from"] or 0, reverse=True)
    elif sortby == "prix_sort_asc":
        rows.sort(key=lambda r: r["price_from"] or 10**9)
    return total, rows


def _detail(uuid, ttl=None):
    payload = _fetch(
        f"/api/product/{urllib.parse.quote(str(uuid))}",
        {"locale": "fr", "workspace": WORKSPACE},
        ttl=ttl,
    )
    if not isinstance(payload, dict):
        raise RuntimeError(f"unreadable detail for {uuid}")
    return payload


def _offers(detail):
    offers = detail.get("offersInfo")
    return offers if isinstance(offers, list) else []


def _sessions_from(detail, date_from=None, date_to=None, departure_city=None):
    """Dated sessions, price per transport variant, filtered on the window."""
    out = []
    for offer in _offers(detail):
        iso = _iso(offer.get("dF"))
        if not iso:
            continue
        if date_from and iso < date_from:
            continue
        if date_to and iso > date_to:
            continue
        city = offer.get("departC") or None
        out.append(
            {
                "date": iso,
                "nights": offer.get("pN"),
                "days": offer.get("pD"),
                "price": _num(offer.get("price")),
                "price_before": _num(offer.get("prePrice")),
                "transport": bool(offer.get("transInc")),
                "departure_city": city,
                "transport_type": offer.get("transType") or None,
                "available": bool(offer.get("available")),
                "stock": offer.get("available_stock"),
                "capacity": offer.get("paxMax"),
                "booked": offer.get("booked_stock"),
                "guaranteed": (offer.get("status") or {}).get("message"),
            }
        )
    out.sort(key=lambda s: (s["date"], s["transport"], s["price"] or 0))
    return out


def _cities(detail):
    cities = set()
    for offer in _offers(detail):
        if offer.get("departC"):
            cities.add(offer["departC"])
    return cities


def _best(sessions, transport=None, cities=None):
    """Lowest price per date: without transport, or with (given city)."""
    picked = {}
    for s in sessions:
        if transport is True and not s["transport"]:
            continue
        if transport is False and s["transport"]:
            continue
        if cities and s["transport"]:
            if not any(c in (s["departure_city"] or "").lower() for c in cities):
                continue
        if not s["available"] or not s["price"]:
            continue
        key = s["date"]
        cur = picked.get(key)
        if cur is None or s["price"] < cur["price"]:
            picked[key] = s
    return [picked[k] for k in sorted(picked)]


def _price_table(
    activities,
    date_from,
    date_to,
    age,
    departure_city,
    max_price,
    transport,
    max_offers,
    sortby,
    ttl,
):
    """Discovery + detail of each product: dated sessions and real prices."""
    filters = _build_filters(
        activities, date_from, date_to, age=age, departure_city=departure_city
    )
    total, products = _collect(
        filters, sortby=sortby, max_items=max_offers, ttl=ttl
    )
    rows = []
    failures = []

    def work(entry):
        try:
            detail = _detail(entry["uuid"], ttl=ttl)
        except RuntimeError as exc:
            failures.append({"uuid": entry["uuid"], "error": str(exc)[:120]})
            return []
        sessions = _sessions_from(detail, date_from, date_to, departure_city)
        best = _best(
            sessions,
            transport=transport,
            cities=[departure_city.lower()] if departure_city else None,
        )
        if max_price is not None:
            best = [s for s in best if (s["price"] or 0) <= float(max_price)]
        if not best:
            return []
        cheapest = best[0]
        return [
            {
                "uuid": entry["uuid"],
                "name": entry["name"],
                "center": entry["center"],
                "activity": entry["activity"],
                "age_range": [entry["age_min"], entry["age_max"]],
                "nights": cheapest["nights"],
                "first_date": cheapest["date"],
                "price": cheapest["price"],
                "price_before": cheapest["price_before"],
                "transport": cheapest["transport"],
                "departure_city": cheapest["departure_city"],
                "stock": cheapest["stock"],
                "guaranteed": cheapest["guaranteed"],
                "dates": [
                    {"date": s["date"], "price": s["price"], "stock": s["stock"]}
                    for s in best
                ],
                "url": entry["url"],
            }
        ]

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for chunk in pool.map(work, products):
            rows.extend(chunk)
    rows.sort(key=lambda r: (r["price"] or 10**9))
    return {
        "query": {
            "activities": _slug_list(activities),
            "date_from": date_from,
            "date_to": date_to,
            "age": age,
            "departure_city": departure_city,
            "max_price": max_price,
            "transport": transport,
        },
        "offers_matched": total,
        "products_scanned": len(products),
        "products_with_prices": len(rows),
        "failures": failures[:5],
        "results": rows,
    }


# ---------------------------------------------------------------- watch state


def _load_watches():
    try:
        with open(WATCH_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"watches": {}}
    if not isinstance(data.get("watches"), dict):
        data["watches"] = {}
    return data


def _save_watches(data):
    _resolve_dir(STATE_DIR)
    tmp = WATCH_FILE + ".tmp"
    with _lock:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, WATCH_FILE)


def _watch_keys(rows, transport):
    """Indexes the sessions of a watch: stable key uuid|date|variant."""
    out = {}
    for row in rows:
        for sess in row["dates"]:
            key = f"{row['uuid']}|{sess['date']}|{transport}"
            out[key] = {
                "price": sess["price"],
                "stock": sess["stock"],
                "name": row["name"],
                "center": row["center"],
                "date": sess["date"],
                "uuid": row["uuid"],
                "transport": transport,
                "url": row["url"],
            }
    return out


def _diff(previous, current):
    new, drop, rise, gone = [], [], [], []
    for key, cur in current.items():
        old = previous.get(key)
        if old is None:
            new.append(cur)
            continue
        old_price, cur_price = old.get("price"), cur.get("price")
        if old_price and cur_price and cur_price < old_price:
            drop.append(
                {
                    "name": cur["name"],
                    "center": cur["center"],
                    "date": cur["date"],
                    "from": old_price,
                    "to": cur_price,
                    "pct": round(100 * (cur_price - old_price) / old_price, 1),
                    "url": cur["url"],
                }
            )
        elif old_price and cur_price and cur_price > old_price:
            rise.append(
                {
                    "name": cur["name"],
                    "center": cur["center"],
                    "date": cur["date"],
                    "from": old_price,
                    "to": cur_price,
                    "pct": round(100 * (cur_price - old_price) / old_price, 1),
                }
            )
    for key, old in previous.items():
        if key not in current:
            gone.append(
                {
                    "name": old.get("name"),
                    "center": old.get("center"),
                    "date": old.get("date"),
                    "last_price": old.get("price"),
                    "url": old.get("url"),
                }
            )
    drop.sort(key=lambda r: r["pct"])
    return {
        "new": sorted(new, key=lambda r: r["price"] or 10**9)[:40],
        "price_drops": drop[:40],
        "price_rises": rise[:40],
        "disappeared": gone[:40],
    }


# --------------------------------------------------------------------- tools


@tool
def ucpa_status() -> str:
    """UCPA server state: API reachable, cache, watches in place.

    Serves as a smoke test: it is the only tool that depends on no filter.
    """
    out = {
        "base": BASE,
        "state_dir": STATE_DIR,
        "cache_files": 0,
        "watches": [],
    }
    try:
        out["cache_files"] = len(os.listdir(CACHE_DIR))
    except OSError:
        out["cache_files"] = 0
    data = _load_watches()
    for name, watch in data["watches"].items():
        out["watches"].append(
            {
                "name": name,
                "last_check": watch.get("last_check"),
                "sessions": len(watch.get("snapshot") or {}),
                "max_price": watch.get("max_price"),
            }
        )
    try:
        probe = _fetch(
            "/api/products",
            {"filters": "{}", "start": 0, "limit": 1},
            ttl=60,
        )
        out["api_ok"] = bool(probe.get("productsGlobalSearch"))
        out["catalogue_size"] = (probe.get("productsGlobalSearch") or {}).get("count")
    except RuntimeError as exc:
        out["api_ok"] = False
        out["api_error"] = str(exc)[:200]
    return json.dumps(out, ensure_ascii=False, separators=(",", ":"))


@tool
def ucpa_activities() -> str:
    """Available UCPA activities (slug + label) and their families.

    The slug is what the search tools expect; `ski` returns the
    complete ski/snowboard family.
    """
    try:
        page = _search_page({}, 0, 1, None, CACHE_TTL)
        facets = page.get("facets") or []
    except RuntimeError as exc:
        raise RuntimeError(str(exc)) from None
    items = []
    for facet in facets:
        if facet.get("id") != "activity_label":
            continue
        for item in facet.get("items") or []:
            items.append(
                {
                    "slug": item.get("filter"),
                    "label": item.get("value"),
                    "offers": item.get("count"),
                }
            )
    return json.dumps(
        {"families": {"ski": SKI_SNOWBOARD}, "activities": items},
        ensure_ascii=False,
        separators=(",", ":"),
    )


@tool
def ucpa_search(
    activities: str = "ski",
    date_from: str = DEFAULT_FROM,
    date_to: str = DEFAULT_TO,
    age: int = 26,
    departure_city: str = "",
    max_price: float = 0,
    sortby: str = "prix_sort_asc",
    max_offers: int = 400,
) -> str:
    """Discovers UCPA stays over a date window, without the sessions.

    Fast (one paginated request, no per-stay detail). Returns a price
    `price_from` that is INDICATIVE, from the list: for a price of a session
    that can be relied on, chain into ucpa_sessions or call ucpa_prices, which reads the
    detail of each stay.

    activities: 'ski' (ski/snowboard family), 'tous', or slugs separated
    by commas ('snowboard,snowboard-freestyle'). See ucpa_activities.
    date_from/date_to: YYYY-MM-DD, default February 2027 (the targeted stay).
    age: eligibility criterion (UCPA does not bill by age on these stays).
    departure_city: transport departure city, e.g. 'Paris' (filter on the API side).
    max_price: 0 = no cap; filter on price_from.
    sortby: pertinence | prix_sort_asc | prix_sort_desc.
    max_offers: bounds the sweep, in OFFERS of the list (ski/snowboard measurement
    February 2027: 1277 offers = 95 stays, ~13 offers per stay).
    """
    filters = _build_filters(
        activities, date_from, date_to, age=age, departure_city=departure_city
    )
    total, products = _collect(
        filters, sortby=sortby, max_items=max_offers
    )
    if max_price:
        products = [
            p for p in products if (p["price_from"] or 0) <= float(max_price)
        ]
    return json.dumps(
        {
            "filters": filters,
            "offers_matched": total,
            "products": len(products),
            "note": "price_from = indicative (list); ucpa_prices/ucpa_sessions "
            "return the session price from the detail",
            "results": products,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


@tool
def ucpa_sessions(
    product: str,
    date_from: str = "",
    date_to: str = "",
    departure_city: str = "",
    refresh: bool = False,
) -> str:
    """Dated sessions and exact prices of a stay (UCPA detail).

    product: uuid ('product_rdd_2703'), ucpa.com URL, or stay code from
    the URL (e.g. 'sfavisn13' in /sejour/sfavisn13-...). Returns, per date, the
    variants without transport and with transport (departure city), with price,
    stock, guaranteed departure status. departure_city filters the variants with
    transport (substring, case-insensitive).
    """
    uuid = _resolve_product(product)
    ttl = 0 if refresh else CACHE_TTL
    detail = _detail(uuid, ttl=ttl)
    sessions = _sessions_from(detail, date_from or None, date_to or None)
    if departure_city:
        wanted = departure_city.lower()
        sessions = [
            s
            for s in sessions
            if not s["transport"] or wanted in (s["departure_city"] or "").lower()
        ]
    return json.dumps(
        {
            "uuid": uuid,
            "url": f"https://www.ucpa.com/api/product/{uuid}",
            "sessions": len(sessions),
            "dates": sessions,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


@tool
def ucpa_prices(
    activities: str = "ski",
    date_from: str = DEFAULT_FROM,
    date_to: str = DEFAULT_TO,
    age: int = 26,
    departure_city: str = "",
    max_price: float = 0,
    transport: str = "sans",
    max_offers: int = 120,
    sortby: str = "prix_sort_asc",
) -> str:
    """Real prices per session for all the stays of a date window.

    The only tool that gives reliable prices: it reads the detail of each
    discovered stay, so it costs ~2 s per stay (disk cache afterwards).
    max_offers bounds the sweep, in OFFERS of the list (ski/snowboard measurement
    February 2027: 1277 offers = 95 stays; count ~13 offers per stay).
    1400 therefore covers the complete inventory of the family over a month.

    transport: 'sans' (default, stay-only price), 'avec' (variant with
    transport, the cheapest), 'indifferent' (the cheapest of the two).
    max_price: 0 = no cap, otherwise filter on the session price.
    """
    mode = {"sans": False, "avec": True, "indifferent": None}.get(
        (transport or "sans").lower(), False
    )
    payload = _price_table(
        activities,
        date_from,
        date_to,
        age,
        departure_city,
        max_price or None,
        mode,
        max_offers,
        sortby,
        None,
    )
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _resolve_product(product):
    """Accepts a stay uuid or a ucpa.com URL (stay code inside)."""
    raw = str(product or "").strip()
    if not raw:
        raise RuntimeError("empty product")
    if raw.startswith("product_"):
        return raw
    if "ucpa.com" in raw:
        raw = raw.split("ucpa.com", 1)[1].split("?", 1)[0].strip("/")
    if "/" in raw:
        raw = raw.rsplit("/", 1)[-1]
    code = raw.split("-", 1)[0]
    if not code:
        raise RuntimeError(f"unreadable stay reference: {product!r}")
    page = _search_page({}, 0, 100, None, CACHE_TTL, query=code)
    for item in page.get("items") or []:
        if f"/{code}-" in (item.get("url") or ""):
            return item["uuid"]
    raise RuntimeError(
        f"no UCPA stay for reference {code!r}; pass the uuid returned "
        "by ucpa_search (uuid field)"
    )


@tool
def ucpa_watch_add(
    name: str,
    activities: str = "ski",
    date_from: str = DEFAULT_FROM,
    date_to: str = DEFAULT_TO,
    age: int = 26,
    departure_city: str = "",
    max_price: float = 0,
    transport: str = "sans",
    max_offers: int = 120,
) -> str:
    """Saves a price watch (named contract) without running it.

    The watch is identified by `name`; re-running it overwrites the previous one.
    The different readings are compared by ucpa_watch_check, which never
    keeps an errored reading. To see prices right away: ucpa_prices.
    """
    data = _load_watches()
    data["watches"][name] = {
        "activities": activities,
        "date_from": date_from,
        "date_to": date_to,
        "age": age,
        "departure_city": departure_city or "",
        "max_price": max_price or 0,
        "transport": transport or "sans",
        "max_offers": int(max_offers),
        "created": int(time.time()),
        "last_check": None,
        "snapshot": {},
        "history": {},
    }
    _save_watches(data)
    return json.dumps(
        {"saved": name, "watch": data["watches"][name]}, ensure_ascii=False
    )


@tool
def ucpa_watch_list() -> str:
    """Saved watches, with their last reading."""
    data = _load_watches()
    rows = []
    for name, watch in data["watches"].items():
        rows.append(
            {
                "name": name,
                "activities": watch.get("activities"),
                "dates": [watch.get("date_from"), watch.get("date_to")],
                "age": watch.get("age"),
                "departure_city": watch.get("departure_city"),
                "max_price": watch.get("max_price"),
                "transport": watch.get("transport"),
                "last_check": watch.get("last_check"),
                "sessions": len(watch.get("snapshot") or {}),
            }
        )
    return json.dumps({"watches": rows}, ensure_ascii=False, separators=(",", ":"))


@tool
def ucpa_watch_remove(name: str) -> str:
    """Removes a watch (and its price history)."""
    data = _load_watches()
    removed = data["watches"].pop(name, None)
    if removed is None:
        raise RuntimeError(f"unknown watch: {name!r}")
    _save_watches(data)
    return json.dumps({"removed": name}, ensure_ascii=False)


@tool
def ucpa_watch_check(name: str = "", max_price_check: bool = True) -> str:
    """Re-runs a watch (or all) and returns the price changes.

    Output: new sessions, drops, rises, disappearances, and the
    sessions that fell below the watch cap. If the API fails for a
    stay, its last reading is kept (never overwritten by an error).

    To be called from a daily cron; it is the 'track prices' building block.
    """
    data = _load_watches()
    names = [name] if name else list(data["watches"])
    if not names:
        raise RuntimeError("no watch: create one with ucpa_watch_add")
    report = []
    for watch_name in names:
        watch = data["watches"].get(watch_name)
        if watch is None:
            report.append({"name": watch_name, "error": "unknown watch"})
            continue
        mode = {"sans": False, "avec": True, "indifferent": None}.get(
            (watch.get("transport") or "sans").lower(), False
        )
        try:
            payload = _price_table(
                watch.get("activities"),
                watch.get("date_from"),
                watch.get("date_to"),
                watch.get("age"),
                watch.get("departure_city") or None,
                None,
                mode,
                int(watch.get("max_offers") or 120),
                "prix_sort_asc",
                0,  # no cache: a watch reading must be fresh
            )
        except RuntimeError as exc:
            report.append(
                {"name": watch_name, "error": str(exc)[:200], "kept": True}
            )
            continue
        current = _watch_keys(payload["results"], watch.get("transport"))
        if not current:
            report.append(
                {
                    "name": watch_name,
                    "error": "no session in this reading, last state kept",
                    "kept": True,
                }
            )
            continue
        previous = watch.get("snapshot") or {}
        changes = _diff(previous, current)
        target = float(watch.get("max_price") or 0)
        hits = (
            [
                {
                    "name": v["name"],
                    "center": v["center"],
                    "date": v["date"],
                    "price": v["price"],
                    "url": v["url"],
                }
                for v in sorted(
                    current.values(), key=lambda r: r["price"] or 10**9
                )
                if target and (v["price"] or 10**9) <= target
            ]
            if max_price_check and target
            else []
        )
        history = watch.get("history") or {}
        now = int(time.time())
        for key, value in current.items():
            points = history.get(key) or []
            points.append([now, value["price"]])
            history[key] = points[-90:]
        watch["snapshot"] = current
        watch["history"] = history
        watch["last_check"] = now
        snapshot_min = min(
            (v["price"] for v in current.values() if v["price"]), default=None
        )
        report.append(
            {
                "name": watch_name,
                "checked_at": now,
                "sessions": len(current),
                "cheapest": snapshot_min,
                "changes": changes,
                "below_max_price": hits[:20],
                "products_scanned": payload["products_scanned"],
                "failures": payload["failures"],
            }
        )
    _save_watches(data)
    return json.dumps({"watches": report}, ensure_ascii=False, separators=(",", ":"))
