"""Outils Costco Same-Day (sameday.costco.com) pour mcp-host.

Pourquoi ce module plutot qu'un serveur MCP dedie : sameday.costco.com est la
vitrine Costco alimentee par Instacart, sans API documentee. Le front appelle
un unique endpoint GraphQL `POST/GET https://sameday.costco.com/graphql` en
PERSISTED QUERIES : le client n'envoie pas le document, seulement
`operationName` + `variables` + `extensions.persistedQuery.sha256Hash`. Le
serveur refuse tout document en clair (`PERSISTED_QUERY_HASH_REQUIRED`) et tout
hash inconnu (`PersistedQueryNotSupported`). Les hashes sont donc des
constantes ci-dessous, liees a une version du bundle front : quand ils
meurent, il faut les re-capturer (procedure en fin de docstring).

Chaine verifiee le 19/11/2026, entierement en HTTP, sans navigateur :

1. SESSION INVITE. Le site est verrouille derriere une porte « Sign in via
   Costco.com / Browse as a guest » : sans cookie de session, `/store/...`
   redirige vers `/?next=...` et `searchResultsPlacements` repond
   `Not Authenticated`. Le cookie `__Host-instacart_sid` (httpOnly) est emis
   par une seule mutation :
     POST /graphql  HomepagePbiCreateGuestUserWithPostalCodeMutation
     {"postalCode": "<ZIP>"}
   Elle cree un utilisateur invite pour ce code postal et rend
   `createGuestUser.token`. Aucun compte, aucun mot de passe, aucun anti-bot
   sur ce chemin (UA generique accepte). Le cookie suffit ensuite pour toutes
   les lectures ; il n'existe PAS d'autres cookies requis.

2. MAGASIN + ZONE. `shopId` et `zoneId` ne sortent d'aucune requete : ils sont
   dans le HTML SSR de la page de recherche, bloc
   `<script id="ssr-query-perf-data">` (JSON url-encode listant les requetes
   executees cote serveur, avec leurs variables). On y lit le couple
   (shopId, zoneId) le plus frequent ; c'est exactement ce que la page
   utilise pour chercher. Les deux dependent du code postal de la session
   invite : 11231 -> (195197, 973), 11211 -> (198521, 973), 90210 et 60601
   ne rendent rien (pas de service Same-Day la-bas). Un `shopId` faux ou un
   `zoneId` faux ne leve pas d'erreur : il rend des prix vides, donc on ne
   devine jamais ces deux valeurs.

3. RECHERCHE. GET /graphql?operationName=SearchResultsPlacements avec
   `query`, `shopId`, `postalCode`, `zoneId`, `first`, et surtout l'entete
   `x-ic-view-layer: true` : sans elle, la reponse est un squelette de mise en
   page sans aucun prix (mesure : 0 `priceString` contre 12 avec). Les articles
   sont dans `placements[].content.items[]` (les placements sans `items` sont
   des emplacements publicitaires). `orderBy` n'accepte que `bestMatch`;
   `priceLowToHigh` passe sur certaines requetes puis echoue sur d'autres, donc
   le tri par prix se fait ici, en local.

4. FICHE ARTICLE. GET /graphql?operationName=Items avec
   `ids` = ["items_<prefixe>-<productId>"] (l'id rendu par la recherche, pas le
   productId seul) + shopId/zoneId/postalCode. Rend le meme objet article.
   URL publique : /store/costco/products/<evergreenUrl>.

Prix : ce sont les prix Same-Day (Instacart), majores par rapport a
l'entrepot, et ils varient par magasin : 11231 et 11211 sont deux magasins
Costco differents avec des prix differents pour le meme article.

Etat : sessions et localisations dans COSTCO_SAMEDAY_STATE_DIR (defaut
~/.local/state/costco-sameday-mcp/state.json). Les localisations sont cachees
LOC_TTL secondes (defaut 24 h) ; une session morte est re-creee
automatiquement au premier `Not Authenticated`.

Env : COSTCO_SAMEDAY_BASE, COSTCO_SAMEDAY_POSTAL (defaut 11231),
COSTCO_SAMEDAY_STATE_DIR, COSTCO_SAMEDAY_TIMEOUT (defaut 30),
COSTCO_SAMEDAY_LOC_TTL (defaut 86400), COSTCO_SAMEDAY_UA.

Re-capturer les hashes quand une reponse dit PersistedQueryNotSupported :
ouvrir une page du site dans un navigateur, onglet Reseau, et relever
`extensions.persistedQuery.sha256Hash` des operations citees ci-dessus (le
hash est dans l'URL de la requete). Les memes hashes apparaissent dans les
URLs du bloc `ssr-query-perf-data` pour les operations rendues cote serveur.
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
except Exception:  # test hors mcp-host : decorateur neutre

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

# UA generique, sans le nom de marc : le site ne demande rien de plus.
UA = os.environ.get(
    "COSTCO_SAMEDAY_UA", "hermes-research/1.0 (+https://marcpartensky.com)"
)

# Hashes persisted query, lies a la version du bundle front (19/11/2026).
HASH_GUEST = "60933aab54d6b3f2add1fec396506dae6ef9b6a1891effbdaf39db129e787446"
HASH_SEARCH = "b8684a2645982222458942525893edc8db68dcacfdbec44ec31125fb3d81bf22"
HASH_ITEMS = "c508afc5ec327c479a58ec7c2b1137d421c99757a33a8f662ded27eee594fc52"
HASH_LOCALITY = "d9afaf4291fc02f16c7093da4cf4fbdd41f060e086ab2f09de31a6d8917e5399"

PERF_RE = re.compile(
    r'<script id="ssr-query-perf-data"[^>]*>(.*?)</script>', re.S
)

_lock = threading.Lock()


# ------------------------------------------------------------------- etat


def _state():
    """Lit l'etat (sessions, localisations) ; dict vide si illisible."""
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
            "code postal invalide : %r (5 chiffres attendus, ex 11231)"
            % (code,)
        )
    return code


# ------------------------------------------------------------------ reseau


def _request(url, sid=None, data=None, view=False, method=None):
    """Appelle le site et rend (statut, corps texte, entetes)."""
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
            "reseau injoignable sur %s : %s" % (url, exc.reason)
        ) from None


def _mint(postal):
    """Cree une session invitee pour ce code postal et rend le cookie."""
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
            "creation de session invitee refusee (HTTP %s sur %s) : %s"
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
        "session invitee sans cookie __Host-instacart_sid : %s" % text[:200]
    )


def _sid(postal, force=False):
    """Rend un cookie de session valide pour ce code postal."""
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
    """Appelle une persisted query et rend `data` (ou leve RuntimeError)."""
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
            "reponse non JSON (HTTP %s) sur %s : %s" % (status, op, text[:200])
        ) from None
    errors = payload.get("errors") or []
    if errors:
        blob = json.dumps(errors)[:400]
        if "PERSISTED_QUERY" in blob.upper():
            raise RuntimeError(
                "hash persisted query perime pour %s (%s) : re-capturer les "
                "hashes du module costco_sameday.py" % (op, blob)
            )
        if "NOT AUTHENTICATED" in blob.upper() or status == 401:
            raise PermissionError(blob)
        raise RuntimeError("erreur GraphQL sur %s : %s" % (op, blob))
    data = payload.get("data")
    if not isinstance(data, dict):
        raise RuntimeError(
            "reponse sans donnees sur %s (HTTP %s) : %s"
            % (op, status, text[:200])
        )
    return data


def _gql_auth(op, variables, sha, postal, view=True):
    """Comme _gql, mais recree la session invitee si elle est morte."""
    sid = _sid(postal)
    try:
        return _gql(op, variables, sha, sid, view=view)
    except PermissionError:
        sid = _sid(postal, force=True)
        return _gql(op, variables, sha, sid, view=view)


# --------------------------------------------------------------- magasin


def _perf_entries(html):
    """Rend les entrees du bloc ssr-query-perf-data (URLs GraphQL SSR)."""
    match = PERF_RE.search(html)
    if not match:
        return []
    try:
        payload = json.loads(urllib.parse.unquote(match.group(1)))
    except ValueError:
        return []
    return payload.get("entries") or []


def _parse_shop_zone(html):
    """Lit le couple (shopId, zoneId) que la page utilise reellement."""
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
    """Ville/etat du code postal (best effort, ne bloque jamais)."""
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
    """Magasin + zone + ville pour un code postal (cache disque)."""
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
            "page magasin illisible (HTTP %s) pour %s" % (status, postal)
        )
    shop, zone = _parse_shop_zone(html)
    if not (shop and zone):
        raise RuntimeError(
            "aucun magasin Costco Same-Day pour le code postal %s "
            "(page sans donnees de magasin : zone non desservie, ou bloc "
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


# --------------------------------------------------------- articles


def _item_row(item):
    """Aplatit un noeud ItemsItem en dict court et stable."""
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
    """Rend (localisation, liste d'articles) pour une recherche."""
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


# ----------------------------------------------------------------- outils


@tool
def costco_sameday_status() -> str:
    """Etat du module Costco Same-Day : session, magasin, zone, disque.

    Sert de smoke test (aucune recherche) : il cree/reutilise une session
    invitee pour le code postal par defaut et rend le magasin resolu.
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
    """Magasin Costco Same-Day, zone tarifaire et ville d'un code postal.

    postal_code : 5 chiffres (defaut : COSTCO_SAMEDAY_POSTAL, sinon 11231).
    Rend shop_id et zone_id reellement utilises par le site : sans eux les
    prix sortent vides. Un code postal non desservi leve une erreur explicite.
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
    """Cherche des produits Costco Same-Day (prix de livraison Instacart).

    query : mots cles ('pork chop', 'paper towels'). first : nombre d'articles
    demandes (le site en rend souvent moins, et pas de pagination connue).
    postal_code : zone de livraison (defaut 11231, Brooklyn). sort :
    'default' (pertinence), 'price_asc' ou 'price_desc' (tri local, l'API
    n'accepte que bestMatch). in_stock_only : masque les ruptures.

    Les prix sont ceux de la livraison Same-Day, majores par rapport a
    l'entrepot, et propres au magasin du code postal : ne pas les presenter
    comme le prix Costco en magasin.
    """
    name = (query or "").strip()
    if not name:
        raise RuntimeError("query vide : donner des mots cles")
    limit = max(1, min(int(first or 12), 60))
    try:
        loc, rows = _search_items(name, limit, _postal(postal_code))
    except RuntimeError as exc:
        raise RuntimeError(str(exc)) from None
    except PermissionError as exc:
        raise RuntimeError("session refusee : %s" % (exc,)) from None
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
    """Nombre utilisable pour trier un prix texte ('$16.27' -> 16.27)."""
    match = re.search(r"(\d+(?:\.\d+)?)", text or "")
    return float(match.group(1)) if match else float("inf")


@tool
def costco_sameday_product(ids: str, postal_code: str = "") -> str:
    """Fiche complete d'un ou plusieurs articles, par identifiant de recherche.

    ids : identifiants rendus par costco_sameday_search (champ `id`, forme
    'items_283-32645'), separes par des virgules. Le `product_id` seul ne
    suffit pas. postal_code : zone de livraison (defaut 11231).
    """
    wanted = [
        part.strip() for part in (ids or "").replace("\n", ",").split(",")
        if part.strip()
    ]
    if not wanted:
        raise RuntimeError("ids vide : passer des identifiants de recherche")
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
