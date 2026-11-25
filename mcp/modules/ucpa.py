"""Outils UCPA (sejours ski/snowboard, prix, veille) pour mcp-host.

Pourquoi ce module plutot qu'un serveur MCP dedie : ucpa.com n'expose aucune
API documentee, mais son front AMP/Vue interroge deux routes JSON publiques,
sans compte ni cle :

  GET /api/products?filters=<json>&start=&limit=&sortby=
      Decouverte. Rend une entree par offre/session, avec le produit
      (uuid, nom, centre, activite, age min/max, url) et un prix indicatif
      nomme ici price_from : ce n'est PAS le prix d'une session datee (mesure
      du 18/11/2026 : 693 en liste contre 1140 en detail pour le meme sejour).
  GET /api/product/<uuid>?locale=fr&workspace=ucpa
      Verite terrain. offersInfo porte les sessions avec date complete
      (dF, DD/MM/YYYY), prix, stock, statut depart garanti, et pour chaque
      session les variantes avec transport (departC = ville de depart).
      ~930 Ko en clair, 23 Ko gzip, ~2 s : on cache sur disque.

Filtres verifies sur l'API (un filtre non honore renverrait 200 + corps
identique) : activity_label, date_start_min, date_start_max (DD/MM/YYYY),
availability=[1], age_list, transport_departure_city, month, season, country,
segment_marketing, price_range, duration. Controle negatif : fevrier 2019
renvoie 0 resultat, donc la fenetre de dates filtre bien.

AGE : UCPA ne facture pas par age sur ces sejours. L'age est un critere
d'ELIGIBILITE (product_age_min/max, et le filtre age_list de l'API). Un
sejour « 18-40 ans » est donc ouvert a 26 ans, un « 14-17 » non.

Cache et veille : tout vit dans UCPA_STATE_DIR (defaut
~/.local/state/ucpa-mcp). Le cache evite de marteler un site qui met 2 a 7 s
par requete ; la veille garde le dernier releve BON par session et ne
l'ecrase jamais avec un releve en erreur.

Env : UCPA_BASE, UCPA_STATE_DIR, UCPA_TIMEOUT (defaut 60),
UCPA_CACHE_TTL (secondes, defaut 3600), UCPA_MAX_WORKERS (defaut 6).
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
except Exception:  # test hors mcp-host : decorateur neutre

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

# Le site est derriere un anti-bot AMP : un UA de navigateur complet est
# necessaire, un UA court se fait jeter. Aucun nom d'utilisateur dedans.
UA = os.environ.get(
    "UCPA_UA",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36",
)

# Familles d'activite telles que les nomme le facet activity_label d'UCPA.
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


# ------------------------------------------------------------------ reseau


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
    """GET JSON avec cache disque. Leve RuntimeError avec le corps brut."""
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
        raise RuntimeError(f"UCPA HTTP {exc.code} sur {path} : {detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"UCPA injoignable ({path}) : {exc.reason}") from None
    except ValueError:
        raise RuntimeError(f"UCPA {path} : reponse non JSON") from None
    _cache_put("json", url, payload)
    return payload


# ------------------------------------------------------------- conversions


def _iso(fr_date):
    """'07/02/2027' -> '2027-02-07'. Rend None si le format surprend."""
    try:
        day, month, year = str(fr_date).split("/")
        return f"{year}-{month}-{day}"
    except (ValueError, AttributeError):
        return None


def _fr(iso_date):
    """'2027-02-01' -> '01/02/2027' (format attendu par l'API de filtres)."""
    parts = str(iso_date).split("-")
    if len(parts) != 3:
        raise RuntimeError(f"date attendue en AAAA-MM-JJ, recu {iso_date!r}")
    return f"{parts[2]}/{parts[1]}/{parts[0]}"


def _num(value, digits=2):
    try:
        return round(float(value), digits)
    except (TypeError, ValueError):
        return None


def _slug_list(activities):
    """Resout les alias ('ski', 'tous') en slugs activity_label d'UCPA."""
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
        # Exclut les sejours sans place sur la fenetre. Verifie : sans ce
        # couple, l'API rend aussi des produits non reservables.
        filters["availability"] = [1]
    if age is not None:
        filters["age_list"] = [int(age)]
    if departure_city:
        filters["transport_departure_city"] = [departure_city]
    if duration:
        filters["duration"] = [duration]
    return filters


# --------------------------------------------------------------- lecture API


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
    """Pagine la decouverte et rend (total, produits uniques tries).

    Les pages sont independantes : elles partent en parallele (6 par defaut).
    Sans ca, un balayage ski/snowboard de fevrier 2027 coute 68 s de bout en
    bout, l'API repondant en 5 s par page de 100 offres.
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
        raise RuntimeError(f"detail illisible pour {uuid}")
    return payload


def _offers(detail):
    offers = detail.get("offersInfo")
    return offers if isinstance(offers, list) else []


def _sessions_from(detail, date_from=None, date_to=None, departure_city=None):
    """Sessions datees, prix par variante transport, filtrees sur la fenetre."""
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
    """Prix le plus bas par date : sans transport, ou avec (ville donnee)."""
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
    """Decouverte + detail de chaque produit : sessions datees et prix reels."""
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


# ---------------------------------------------------------------- etat veille


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
    """Indexe les sessions d'une veille : cle stable uuid|date|variante."""
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
    """Etat du serveur UCPA : API joignable, cache, veilles en place.

    Sert de smoke test : c'est le seul outil qui ne depend d'aucun filtre.
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
    """Activites UCPA disponibles (slug + libelle) et leurs familles.

    Le slug est ce qu'attendent les outils de recherche ; `ski` rend la
    famille ski/snowboard complete.
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
    """Decouvre les sejours UCPA sur une fenetre de dates, sans les sessions.

    Rapide (une requete paginee, pas de detail par sejour). Rend un prix
    `price_from` INDICATIF issu de la liste : pour un prix de session
    opposable, enchainer sur ucpa_sessions ou appeler ucpa_prices, qui lit le
    detail de chaque sejour.

    activities : 'ski' (famille ski/snowboard), 'tous', ou des slugs separes
    par des virgules ('snowboard,snowboard-freestyle'). Voir ucpa_activities.
    date_from/date_to : AAAA-MM-JJ, defaut fevrier 2027 (le sejour vise).
    age : critere d'eligibilite (UCPA ne facture pas par age sur ces sejours).
    departure_city : ville de depart transport, ex 'Paris' (filtre cote API).
    max_price : 0 = pas de plafond ; filtre sur price_from.
    sortby : pertinence | prix_sort_asc | prix_sort_desc.
    max_offers : borne le balayage, en OFFRES de la liste (mesure ski/snowboard
    fevrier 2027 : 1277 offres = 95 sejours, ~13 offres par sejour).
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
            "note": "price_from = indicatif (liste) ; ucpa_prices/ucpa_sessions "
            "rendent le prix de session issu du detail",
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
    """Sessions datees et prix exacts d'un sejour (detail UCPA).

    product : uuid ('product_rdd_2703'), URL ucpa.com, ou code sejour de
    l'URL (ex 'sfavisn13' dans /sejour/sfavisn13-...). Rend, par date, les
    variantes sans transport et avec transport (ville de depart), avec prix,
    stock, statut depart garanti. departure_city filtre les variantes avec
    transport (sous-chaine, insensible a la casse).
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
    """Prix reels par session pour tous les sejours d'une fenetre de dates.

    Le seul outil qui donne des prix opposes : il lit le detail de chaque
    sejour decouvert, donc il coute ~2 s par sejour (cache disque ensuite).
    max_offers borne le balayage, en OFFRES de la liste (mesure ski/snowboard
    fevrier 2027 : 1277 offres = 95 sejours ; compter ~13 offres par sejour).
    1400 couvre donc l'inventaire complet de la famille sur un mois.

    transport : 'sans' (defaut, prix sejour seul), 'avec' (variante avec
    transport, la moins chere), 'indifferent' (le moins cher des deux).
    max_price : 0 = pas de plafond, sinon filtre sur le prix de session.
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
    """Accepte un uuid de sejour ou une URL ucpa.com (code sejour dedans)."""
    raw = str(product or "").strip()
    if not raw:
        raise RuntimeError("product vide")
    if raw.startswith("product_"):
        return raw
    if "ucpa.com" in raw:
        raw = raw.split("ucpa.com", 1)[1].split("?", 1)[0].strip("/")
    if "/" in raw:
        raw = raw.rsplit("/", 1)[-1]
    code = raw.split("-", 1)[0]
    if not code:
        raise RuntimeError(f"reference de sejour illisible : {product!r}")
    page = _search_page({}, 0, 100, None, CACHE_TTL, query=code)
    for item in page.get("items") or []:
        if f"/{code}-" in (item.get("url") or ""):
            return item["uuid"]
    raise RuntimeError(
        f"aucun sejour UCPA pour la reference {code!r} ; passer l'uuid rendu "
        "par ucpa_search (champ uuid)"
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
    """Enregistre une veille de prix (contrat nomme) sans la lancer.

    La veille est identifiee par `name` ; la relancer ecrase la precedente.
    Les differents releves sont compares par ucpa_watch_check, qui ne garde
    jamais un releve en erreur. Voir les prix tout de suite : ucpa_prices.
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
    """Veilles enregistrees, avec leur dernier releve."""
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
    """Supprime une veille (et son historique de prix)."""
    data = _load_watches()
    removed = data["watches"].pop(name, None)
    if removed is None:
        raise RuntimeError(f"veille inconnue : {name!r}")
    _save_watches(data)
    return json.dumps({"removed": name}, ensure_ascii=False)


@tool
def ucpa_watch_check(name: str = "", max_price_check: bool = True) -> str:
    """Relance une veille (ou toutes) et rend les changements de prix.

    Sortie : sessions nouvelles, baisses, hausses, disparitions, et les
    sessions passees sous le plafond de la veille. Si l'API echoue pour un
    sejour, son dernier releve est conserve (jamais ecrase par une erreur).

    A appeler depuis un cron quotidien ; c'est la brique 'tracker les prix'.
    """
    data = _load_watches()
    names = [name] if name else list(data["watches"])
    if not names:
        raise RuntimeError("aucune veille : creer avec ucpa_watch_add")
    report = []
    for watch_name in names:
        watch = data["watches"].get(watch_name)
        if watch is None:
            report.append({"name": watch_name, "error": "veille inconnue"})
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
                0,  # pas de cache : un releve de veille doit etre frais
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
                    "error": "aucune session sur ce releve, dernier etat conserve",
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
