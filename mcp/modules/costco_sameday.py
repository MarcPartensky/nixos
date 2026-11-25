"""Costco Same-Day tools (sameday.costco.com) for mcp-host.

Why this module rather than a dedicated MCP server: sameday.costco.com is the
Costco storefront powered by Instacart, with no documented API. The front end calls
a single GraphQL endpoint `POST/GET https://sameday.costco.com/graphql` with
PERSISTED QUERIES: the client does not send the document, only
`operationName` + `variables` + `extensions.persistedQuery.sha256Hash`. The
server refuses any cleartext document (`PERSISTED_QUERY_HASH_REQUIRED`) and any
unknown hash (`PersistedQueryNotSupported`). The hashes are therefore the
constants below, tied to a version of the front bundle: when they
die, they must be re-captured (procedure at the end of the docstring).

Chain verified on 19/11/2026, entirely over HTTP, without a browser:

1. GUEST SESSION. The site is locked behind a gate "Sign in via
   Costco.com / Browse as a guest": without a session cookie, `/store/...`
   redirects to `/?next=...` and `searchResultsPlacements` answers
   `Not Authenticated`. The cookie `__Host-instacart_sid` (httpOnly) is issued
   by a single mutation:
     POST /graphql  HomepagePbiCreateGuestUserWithPostalCodeMutation
     {"postalCode": "<ZIP>"}
   It creates a guest user for this postal code and returns
   `createGuestUser.token`. No account, no password, no anti-bot
   on this path (generic UA accepted). The cookie then suffices for all
   the reads; there is NO other required cookie.

2. STORE + ZONE. `shopId` and `zoneId` do not come out of any request: they are
   in the SSR HTML of the search page, block
   `<script id="ssr-query-perf-data">` (url-encoded JSON listing the requests
   executed server-side, with their variables). There we read the most
   frequent (shopId, zoneId) pair; it is exactly what the page
   uses to search. The two depend on the postal code of the guest
   session: 11231 -> (195197, 973), 11211 -> (198521, 973), 90210 and 60601
   return nothing (no Same-Day service there). A wrong `shopId` or a
   wrong `zoneId` does not raise an error: it returns empty prices, so we never
   guess these two values.

3. SEARCH. GET /graphql?operationName=SearchResultsPlacements with
   `query`, `shopId`, `postalCode`, `zoneId`, `first`, and above all the header
   `x-ic-view-layer: true`: without it, the response is a layout
   skeleton with no price at all (measurement: 0 `priceString` versus 12 with). The items
   are in `placements[].content.items[]` (placements without `items` are
   ad slots). `orderBy` only accepts `bestMatch`;
   `priceLowToHigh` works on some requests then fails on others, so
   the price sort is done here, locally.

4. ITEM PAGE. GET /graphql?operationName=Items with
   `ids` = ["items_<prefix>-<productId>"] (the id returned by the search, not the
   productId alone) + shopId/zoneId/postalCode. Returns the same item object.
   Public URL: /store/costco/products/<evergreenUrl>.

Prices: these are the Same-Day (Instacart) prices, marked up compared to
the warehouse, and they vary per store: 11231 and 11211 are two different
Costco stores with different prices for the same item.

State: sessions and locations in COSTCO_SAMEDAY_STATE_DIR (default
~/.local/state/costco-sameday-mcp/state.json). The locations are cached
LOC_TTL seconds (default 24 h); a dead session is re-created
automatically on the first `Not Authenticated`.

Env: COSTCO_SAMEDAY_BASE, COSTCO_SAMEDAY_POSTAL (default 11231),
COSTCO_SAMEDAY_STATE_DIR, COSTCO_SAMEDAY_TIMEOUT (default 30),
COSTCO_SAMEDAY_LOC_TTL (default 86400), COSTCO_SAMEDAY_UA.

Re-capture the hashes when a response says PersistedQueryNotSupported:
open a page of the site in a browser, Network tab, and note
`extensions.persistedQuery.sha256Hash` of the operations cited above (the
hash is in the request URL). The same hashes appear in the
URLs of the `ssr-query-perf-data` block for the operations rendered server-side.
"""

import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

try:
    from fastmcp.tools import tool
except Exception:  # test outside mcp-host: neutral decorator

    def tool(fn=None, **_kw):
        if fn is not None:
            return fn
        return lambda f: f


BASE = os.environ.get(
    "COSTCO_SAMEDAY_BASE", "https://sameday.costco.com"
).rstrip("/")
STATE_DIR = os.environ.get(
    "COSTCO_SAMEDAY_STATE_DIR",
    os.path.join(
        os.path.expanduser("~"), ".local", "state", "costco-sameday-mcp"
    ),
)
STATE_FILE = os.path.join(STATE_DIR, "state.json")
DEFAULT_POSTAL = os.environ.get("COSTCO_SAMEDAY_POSTAL", "11231")
TIMEOUT = float(os.environ.get("COSTCO_SAMEDAY_TIMEOUT", "30"))
LOC_TTL = float(os.environ.get("COSTCO_SAMEDAY_LOC_TTL", "86400"))

# Generic UA, without marc's name: the site asks for nothing more.
UA = os.environ.get(
    "COSTCO_SAMEDAY_UA", "hermes-research/1.0 (+https://marcpartensky.com)"
)

# Persisted query hashes, tied to the version of the front bundle (19/11/2026).
HASH_GUEST = "60933aab54d6b3f2add1fec396506dae6ef9b6a1891effbdaf39db129e787446"
HASH_SEARCH = "b8684a2645982222458942525893edc8db68dcacfdbec44ec31125fb3d81bf22"
HASH_ITEMS = "c508afc5ec327c479a58ec7c2b1137d421c99757a33a8f662ded27eee594fc52"
HASH_LOCALITY = "d9afaf4291fc02f16c7093da4cf4fbdd41f060e086ab2f09de31a6d8917e5399"

PERF_RE = re.compile(
    r'<script id="ssr-query-perf-data"[^>]*>(.*?)</script>', re.S
)

_lock = threading.Lock()


# ------------------------------------------------------------------- state


def _state():
    """Reads the state (sessions, locations); empty dict if unreadable."""
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    data.setdefault("sessions", {})
    data.setdefault("locations", {})
    return data


def _save(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_FILE)


def _postal(postal_code):
    code = (postal_code or "").strip() or DEFAULT_POSTAL
    if not re.fullmatch(r"\d{5}", code):
        raise RuntimeError(
            "invalid postal code: %r (5 digits expected, e.g. 11231)"
            % (code,)
        )
    return code


# ------------------------------------------------------------------ network


def _request(url, sid=None, data=None, view=False, method=None):
    """Calls the site and returns (status, text body, headers)."""
    headers = {
        "user-agent": UA,
        "accept": "*/*",
        "accept-language": "en-US,en;q=0.9",
    }
    if data is not None:
        headers["content-type"] = "application/json"
        headers["x-client-identifier"] = "web"
        headers["origin"] = BASE
    if view:
        headers["x-client-identifier"] = "web"
        headers["x-ic-view-layer"] = "true"
    if sid:
        headers["cookie"] = "__Host-instacart_sid=" + sid
    req = urllib.request.Request(
        url,
        data=None if data is None else json.dumps(data).encode(),
        headers=headers,
        method=method or ("POST" if data is not None else "GET"),
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
            return res.status, res.read().decode("utf-8", "replace"), res
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        return exc.code, body, exc
    except urllib.error.URLError as exc:
        raise RuntimeError(
            "network unreachable on %s: %s" % (url, exc.reason)
        ) from None


def _mint(postal):
    """Creates a guest session for this postal code and returns the cookie."""
    body = {
        "operationName": (
            "HomepagePbiCreateGuestUserWithPostalCodeMutation"
        ),
        "variables": {"postalCode": postal},
        "extensions": {"persistedQuery": {"version": 1,
                                          "sha256Hash": HASH_GUEST}},
    }
    status, text, res = _request(BASE + "/graphql", data=body)
    if status != 200:
        raise RuntimeError(
            "guest session creation refused (HTTP %s on %s): %s"
            % (status, "/graphql", text[:300])
        )
    cookies = []
    try:
        cookies = res.headers.get_all("Set-Cookie") or []
    except Exception:
        raw = res.headers.get("Set-Cookie") or ""
        cookies = [raw] if raw else []
    for raw in cookies:
        name, _, rest = raw.partition("=")
        if name.strip() == "__Host-instacart_sid":
            sid = rest.split(";")[0].strip()
            if sid:
                return sid
    raise RuntimeError(
        "guest session without __Host-instacart_sid cookie: %s" % text[:200]
    )


def _sid(postal, force=False):
    """Returns a valid session cookie for this postal code."""
    with _lock:
        state = _state()
        if not force:
            cached = state["sessions"].get(postal) or {}
            if cached.get("sid"):
                return cached["sid"]
        sid = _mint(postal)
        state["sessions"][postal] = {"sid": sid, "ts": time.time()}
        _save(state)
        return sid


def _gql(op, variables, sha, sid, view=True):
    """Calls a persisted query and returns `data` (or raises RuntimeError)."""
    query = urllib.parse.urlencode(
        {
            "operationName": op,
            "variables": json.dumps(variables, separators=(",", ":")),
            "extensions": json.dumps(
                {"persistedQuery": {"version": 1, "sha256Hash": sha}},
                separators=(",", ":"),
            ),
        }
    )
    status, text, _res = _request(
        "%s/graphql?%s" % (BASE, query), sid=sid, view=view
    )
    try:
        payload = json.loads(text)
    except ValueError:
        raise RuntimeError(
            "non-JSON response (HTTP %s) on %s: %s" % (status, op, text[:200])
        ) from None
    errors = payload.get("errors") or []
    if errors:
        blob = json.dumps(errors)[:400]
        if "PERSISTED_QUERY" in blob.upper():
            raise RuntimeError(
                "stale persisted query hash for %s (%s): re-capture the "
                "hashes of the costco_sameday.py module" % (op, blob)
            )
        if "NOT AUTHENTICATED" in blob.upper() or status == 401:
            raise PermissionError(blob)
        raise RuntimeError("GraphQL error on %s: %s" % (op, blob))
    data = payload.get("data")
    if not isinstance(data, dict):
        raise RuntimeError(
            "response without data on %s (HTTP %s): %s"
            % (op, status, text[:200])
        )
    return data


def _gql_auth(op, variables, sha, postal, view=True):
    """Like _gql, but re-creates the guest session if it is dead."""
    sid = _sid(postal)
    try:
        return _gql(op, variables, sha, sid, view=view)
    except PermissionError:
        sid = _sid(postal, force=True)
        return _gql(op, variables, sha, sid, view=view)


# --------------------------------------------------------------- store


def _perf_entries(html):
    """Returns the entries of the ssr-query-perf-data block (SSR GraphQL URLs)."""
    match = PERF_RE.search(html)
    if not match:
        return []
    try:
        payload = json.loads(urllib.parse.unquote(match.group(1)))
    except ValueError:
        return []
    return payload.get("entries") or []


def _parse_shop_zone(html):
    """Reads the (shopId, zoneId) pair that the page actually uses."""
    shops = {}
    pairs = {}
    zones = {}
    for entry in _perf_entries(html):
        url = entry.get("url") or ""
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        try:
            variables = json.loads((query.get("variables") or ["{}"])[0])
        except ValueError:
            continue
        shop = variables.get("shopId")
        if not shop and variables.get("shopIds"):
            shop = variables["shopIds"][0]
        zone = variables.get("zoneId")
        if shop:
            shops[str(shop)] = shops.get(str(shop), 0) + 1
        if zone:
            zones[str(zone)] = zones.get(str(zone), 0) + 1
        if shop and zone:
            key = (str(shop), str(zone))
            pairs[key] = pairs.get(key, 0) + 1
    if pairs:
        best = max(pairs.items(), key=lambda kv: kv[1])[0]
        return best
    if shops and zones:
        shop = max(shops.items(), key=lambda kv: kv[1])[0]
        zone = max(zones.items(), key=lambda kv: kv[1])[0]
        return shop, zone
    return None, None


def _city_state(postal, sid):
    """City/state of the postal code (best effort, never blocks)."""
    try:
        data = _gql(
            "Locality", {"code": postal}, HASH_LOCALITY, sid, view=False
        )
        locality = data.get("locality") or {}
        section = locality.get("viewSection") or {}
        return section.get("cityStateString") or ""
    except Exception:
        return ""


def _location(postal_code):
    """Store + zone + city for a postal code (disk cache)."""
    postal = _postal(postal_code)
    state = _state()
    cached = state["locations"].get(postal) or {}
    if cached.get("shop_id") and time.time() - cached.get("ts", 0) < LOC_TTL:
        return cached
    sid = _sid(postal)
    status, html, _res = _request(
        "%s/store/costco/s?k=milk" % BASE, sid=sid
    )
    if status != 200:
        raise RuntimeError(
            "unreadable store page (HTTP %s) for %s" % (status, postal)
        )
    shop, zone = _parse_shop_zone(html)
    if not (shop and zone):
        raise RuntimeError(
            "no Costco Same-Day store for postal code %s "
            "(page without store data: zone not served, or block "
            "ssr-query-perf-data absent)" % postal
        )
    loc = {
        "postal_code": postal,
        "shop_id": shop,
        "zone_id": zone,
        "city_state": _city_state(postal, sid),
        "ts": time.time(),
    }
    with _lock:
        state = _state()
        state["locations"][postal] = loc
        _save(state)
    return loc


# --------------------------------------------------------------- items


def _item_row(item):
    """Flattens an ItemsItem node into a short, stable dict."""
    price = (item.get("price") or {}).get("viewSection") or {}
    card = price.get("itemCard") or {}
    weight = (price.get("parWeightTotalEstimate") or {}).get("viewSection")
    availability = item.get("availability") or {}
    slug = item.get("evergreenUrl")
    return {
        "id": item.get("id"),
        "name": item.get("name"),
        "brand": item.get("brandName"),
        "size": item.get("size"),
        "weight": (weight or {}).get("parWeightString"),
        "price": price.get("priceString"),
        "unit_price": card.get("pricePerUnitString"),
        "was_price": price.get("fullPriceString"),
        "in_stock": bool(availability.get("available"))
        and availability.get("stockLevel") == "inStock",
        "product_id": item.get("productId"),
        "url": ("%s/store/costco/products/%s" % (BASE, slug)) if slug
        else None,
    }


def _search_items(query, first, postal):
    """Returns (location, list of items) for a search."""
    loc = _location(postal)
    sid = _sid(postal)
    variables = {
        "action": None,
        "query": query,
        "pageViewId": str(uuid.uuid4()),
        "elevatedProductId": None,
        "searchSource": "search",
        "filters": [],
        "disableReformulation": False,
        "disableLlm": False,
        "forceInspiration": False,
        "orderBy": "bestMatch",
        "clusterId": None,
        "includeDebugInfo": False,
        "clusteringStrategy": None,
        "contentManagementSearchParams": {"itemGridColumnCount": 6},
        "shopId": loc["shop_id"],
        "postalCode": postal,
        "zoneId": loc["zone_id"],
        "first": first,
    }
    try:
        data = _gql("SearchResultsPlacements", variables, HASH_SEARCH, sid)
    except PermissionError:
        sid = _sid(postal, force=True)
        data = _gql("SearchResultsPlacements", variables, HASH_SEARCH, sid)
    placements = (data.get("searchResultsPlacements") or {}).get(
        "placements"
    ) or []
    rows = []
    for placement in placements:
        content = placement.get("content") or {}
        for item in content.get("items") or []:
            rows.append(_item_row(item))
    return loc, rows


# ------------------------------------------------------------------ tools


@tool
def costco_sameday_status() -> str:
    """Costco Same-Day module state: session, store, zone, disk.

    Serves as a smoke test (no search): it creates/reuses a guest
    session for the default postal code and returns the resolved store.
    """
    out: dict = {
        "base": BASE,
        "default_postal": DEFAULT_POSTAL,
        "state_file": STATE_FILE,
    }
    try:
        out["location"] = _location(DEFAULT_POSTAL)
        out["session"] = "ok"
    except RuntimeError as exc:
        out["session"] = "ko"
        out["error"] = str(exc)
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


@tool
def costco_sameday_location(postal_code: str = "") -> str:
    """Costco Same-Day store, pricing zone and city of a postal code.

    postal_code: 5 digits (default: COSTCO_SAMEDAY_POSTAL, otherwise 11231).
    Returns shop_id and zone_id actually used by the site: without them the
    prices come out empty. A postal code that is not served raises an explicit error.
    """
    try:
        return json.dumps(
            _location(postal_code), separators=(",", ":"), ensure_ascii=False
        )
    except RuntimeError as exc:
        raise RuntimeError(str(exc)) from None


@tool
def costco_sameday_search(
    query: str,
    first: int = 12,
    postal_code: str = "",
    sort: str = "default",
    in_stock_only: bool = False,
) -> str:
    """Searches Costco Same-Day products (Instacart delivery prices).

    query: keywords ('pork chop', 'paper towels'). first: number of items
    requested (the site often returns fewer, and no known pagination).
    postal_code: delivery zone (default 11231, Brooklyn). sort:
    'default' (relevance), 'price_asc' or 'price_desc' (local sort, the API
    only accepts bestMatch). in_stock_only: hides out-of-stock items.

    The prices are those of Same-Day delivery, marked up compared to
    the warehouse, and specific to the store of the postal code: do not present them
    as the in-store Costco price.
    """
    name = (query or "").strip()
    if not name:
        raise RuntimeError("empty query: give some keywords")
    limit = max(1, min(int(first or 12), 60))
    try:
        loc, rows = _search_items(name, limit, _postal(postal_code))
    except RuntimeError as exc:
        raise RuntimeError(str(exc)) from None
    except PermissionError as exc:
        raise RuntimeError("session refused: %s" % (exc,)) from None
    if in_stock_only:
        rows = [row for row in rows if row["in_stock"]]
    if sort == "price_asc":
        rows.sort(key=lambda r: _price_value(r["price"]))
    elif sort == "price_desc":
        rows.sort(key=lambda r: _price_value(r["price"]), reverse=True)
    payload = {
        "query": name,
        "location": {
            key: loc[key]
            for key in ("postal_code", "city_state", "shop_id", "zone_id")
        },
        "count": len(rows),
        "products": rows[:limit],
    }
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


def _price_value(text):
    """Usable number to sort a text price ('$16.27' -> 16.27)."""
    match = re.search(r"(\d+(?:\.\d+)?)", text or "")
    return float(match.group(1)) if match else float("inf")


@tool
def costco_sameday_product(ids: str, postal_code: str = "") -> str:
    """Full record of one or more items, by search identifier.

    ids: identifiers returned by costco_sameday_search (`id` field, form
    'items_283-32645'), separated by commas. The `product_id` alone is not
    enough. postal_code: delivery zone (default 11231).
    """
    wanted = [
        part.strip() for part in (ids or "").replace("\n", ",").split(",")
        if part.strip()
    ]
    if not wanted:
        raise RuntimeError("empty ids: pass some search identifiers")
    postal = _postal(postal_code)
    try:
        loc = _location(postal)
        data = _gql_auth(
            "Items",
            {
                "ids": wanted,
                "shopId": loc["shop_id"],
                "zoneId": loc["zone_id"],
                "postalCode": postal,
            },
            HASH_ITEMS,
            postal,
        )
    except RuntimeError as exc:
        raise RuntimeError(str(exc)) from None
    rows = [_item_row(item) for item in (data.get("items") or [])]
    payload = {
        "location": {
            key: loc[key]
            for key in ("postal_code", "city_state", "shop_id", "zone_id")
        },
        "count": len(rows),
        "products": rows,
    }
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
