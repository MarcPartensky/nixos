"""Outils transport (train + car + navette) pour mcp-host.

Pourquoi ce module : pour aller a un centre UCPA, l'API SNCF (Navitia) ne
suffit pas. Elle ne connait que le rail : le dernier tronçon (car regional,
navette de station, car interurbain) manque, et c'est justement celui qui
dessert les stations. Un serveur MCP adosse a Navitia seul oblige donc a
recoller a la main train et car.

Ici tout passe par Transitous (https://transitous.org), une instance MOTIS
publique qui agrege les GTFS de toute l'Europe : horaires SNCF (feed
fr-horaires-sncf), cars regionaux (Savoie, Hautes-Alpes, Occitanie...),
navettes de station (Bourg-Saint-Maurice, Tignes, Val d'Isere), FlixBus et
BlaBlaCar Bus. Un seul appel rend l'itineraire porte a porte, train et car
melanges, avec les correspondances calculees.

Pourquoi pas de graphe local (OpenTripPlanner / MOTIS auto-heberge) : le
graphe France entiere pese plusieurs Go de RAM et coute des heures de CPU a
construire, pour un resultat identique. Ici le cout local est nul : un GET
JSON de ~1 s, aucune dependance hors stdlib, aucun cache de graphe.

Limites mesurees le 18/11/2026 :
- Aucun prix. Ni Transitous ni Navitia ne vendent des billets ; les prix
  SNCF Connect sont derriere une API privee non officielle.
- Temps reel partiel : chaque feed expose ou non du GTFS-RT. Le champ
  realTime de chaque tronçon dit ce qui est confirme (NO_RT_DATA sinon).
- Trou de couverture constate depuis Paris : Les Orres 1650 et Val Cenis
  Lanslebourg ne rendent aucun itineraire (car de rabattement absent des
  feeds) alors que 18 autres centres UCPA passent.

Env : TRANSPORT_BASE (defaut https://api.transitous.org/api/v1),
TRANSPORT_TIMEOUT (defaut 40), TRANSPORT_STATE_DIR (cache geocodage),
TRANSPORT_TZ (defaut Europe/Paris).
"""

import json
import math
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

try:
    from fastmcp.tools import tool
except Exception:  # test hors mcp-host : decorateur neutre

    def tool(fn=None, **_kw):
        if fn is not None:
            return fn
        return lambda f: f

BASE = os.environ.get("TRANSPORT_BASE", "https://api.transitous.org/api/v1").rstrip("/")
TIMEOUT = float(os.environ.get("TRANSPORT_TIMEOUT", "40"))
TZ = os.environ.get("TRANSPORT_TZ", "Europe/Paris")
STATE_DIR = os.environ.get(
    "TRANSPORT_STATE_DIR",
    os.path.join(os.path.expanduser("~"), ".local", "state", "transport-mcp"),
)
GEO_CACHE = os.path.join(STATE_DIR, "geocode.json")
GEO_TTL = 30 * 24 * 3600

# Transitous demande un UA identifiable ; jamais le nom de marc dedans.
UA = os.environ.get("TRANSPORT_UA", "hermes-transport-mcp/1.0 (+self-hosted)")

# Centres UCPA atteignables, coordonnees de l'arret le plus proche verifiees
# par un itineraire reel depuis Paris le 18/11/2026. `note` dit ce qui a ete
# constate, `gap` signale un centre ou le car de rabattement manque.
UCPA_CENTERS = {
    "val-thorens": {
        "label": "UCPA Val Thorens",
        "lat": 45.29965,
        "lon": 6.569263,
        "note": "arret 'VAL THORENS UCPA' du car regional Savoie (S63 depuis Moutiers)",
    },
    "valloire": {
        "label": "UCPA Valloire",
        "lat": 45.15585,
        "lon": 6.42073,
        "note": "arret 'VALLOIRE UCPA' du car regional Savoie (S40 depuis Saint-Michel)",
    },
    "val-d-isere": {
        "label": "UCPA Val d'Isere",
        "lat": 45.459877,
        "lon": 6.965673,
        "note": "car S82 depuis Bourg-Saint-Maurice",
    },
    "tignes": {
        "label": "UCPA Tignes",
        "lat": 45.4694,
        "lon": 6.9049,
        "note": "car S83 depuis Bourg-Saint-Maurice",
    },
    "les-arcs": {
        "label": "UCPA Les Arcs (Arc 1600)",
        "lat": 45.59905,
        "lon": 6.79973,
        "note": "funiculaire depuis Bourg-Saint-Maurice (gare dans le graphe)",
    },
    "la-plagne": {
        "label": "UCPA La Plagne Le France",
        "lat": 45.506763,
        "lon": 6.675743,
        "note": "car S71 depuis Aime-la-Plagne ; coordonnees de Plagne Centre, centre a ~1 km",
    },
    "chamonix": {
        "label": "UCPA Chamonix",
        "lat": 45.92277,
        "lon": 6.87363,
        "note": "TGV jusqu'a Saint-Gervais ou Sallanches, puis BlaBlaCar Bus / TER",
    },
    "argentiere": {
        "label": "UCPA Argentiere (Vallee du Mont-Blanc)",
        "lat": 45.981944,
        "lon": 6.926484,
        "note": "TER Chamonix puis marche ; le car BlaBlaCar Bus s'arrete a Chamonix",
    },
    "les-contamines": {
        "label": "UCPA Les Contamines",
        "lat": 45.82238,
        "lon": 6.72685,
        "note": "car Y84 depuis Sallanches / Saint-Gervais",
    },
    "flaine": {
        "label": "UCPA Flaine",
        "lat": 46.005558,
        "lon": 6.692669,
        "note": "navette LCFE depuis Cluses (arret 'FLAINE - FORUM')",
    },
    "pralognan": {
        "label": "UCPA Pralognan",
        "lat": 45.388622,
        "lon": 6.716409,
        "note": "car S66 depuis Moutiers",
    },
    "les-orres": {
        "label": "UCPA Les Orres",
        "lat": 44.49429,
        "lon": 6.55675,
        "note": "car de rabattement absent des feeds : 0 itineraire mesure, viser Embrun puis car local",
        "gap": True,
    },
    "les-deux-alpes": {
        "label": "UCPA Les Deux Alpes (Venosc)",
        "lat": 45.0105,
        "lon": 6.1246,
        "note": "car depuis Grenoble puis Venosc ; coordonnees de la station (la telecabine de Venosc n'est pas dans le graphe)",
    },
    "val-cenis": {
        "label": "UCPA Val Cenis",
        "lat": 45.28539,
        "lon": 6.8755,
        "note": "car de rabattement absent des feeds : 0 itineraire mesure, viser Modane puis car local",
        "gap": True,
    },
    "serre-chevalier": {
        "label": "UCPA Serre Chevalier (Monetier)",
        "lat": 44.9763,
        "lon": 6.507302,
        "note": "TER jusqu'a Briancon puis car ZOU / lignes locales",
    },
    "saint-lary": {
        "label": "UCPA Saint-Lary-Soulan",
        "lat": 42.818394,
        "lon": 0.322091,
        "note": "train jusqu'a Lannemezan ou Tarbes puis car regional",
    },
    "guchen": {
        "label": "UCPA Guchen (Vallee de Saint-Lary)",
        "lat": 42.86289,
        "lon": 0.338455,
        "note": "meme acces que Saint-Lary, arret amont",
    },
    "valmeinier": {
        "label": "UCPA Valmeinier",
        "lat": 45.17964,
        "lon": 6.48492,
        "note": "car S41 depuis Saint-Michel - Valloire",
    },
    "chapelle-vercors": {
        "label": "UCPA La Chapelle-en-Vercors",
        "lat": 44.964764,
        "lon": 5.414576,
        "note": "TGV jusqu'a Valence puis car D05",
    },
    "vallouise": {
        "label": "UCPA Vallouise (Ecrins)",
        "lat": 44.84532,
        "lon": 6.4899,
        "note": "TER jusqu'a Briancon puis car L1",
    },
}

_FRENCH = {"FR", "MC"}


# ------------------------------------------------------------------ reseau


def _get(path, params=None):
    """GET JSON sur Transitous. Leve RuntimeError avec le corps d'erreur."""
    url = f"{BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url, headers={"User-Agent": UA, "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise RuntimeError(f"Transitous HTTP {exc.code} sur /{path} : {detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Transitous injoignable (/{path}) : {exc.reason}") from None
    except ValueError:
        raise RuntimeError(f"Transitous /{path} : reponse non JSON") from None


def _fold(text):
    """Minuscule sans accents, pour comparer 'Moutiers' et 'Moutiers'."""
    raw = unicodedata.normalize("NFKD", str(text or ""))
    return "".join(c for c in raw if not unicodedata.combining(c)).lower().strip()


def _geo_cache():
    try:
        with open(GEO_CACHE, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _geo_remember(query, payload):
    data = _geo_cache()
    data[query] = {"at": int(time.time()), "payload": payload}
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = GEO_CACHE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.replace(tmp, GEO_CACHE)
    except OSError:
        pass


def _geocode_raw(query, limit=8, kind="STOP"):
    key = f"{kind}:{limit}:{query}"
    cached = _geo_cache().get(key)
    if cached and time.time() - cached.get("at", 0) < GEO_TTL:
        return cached["payload"]
    params = {"text": query, "n": max(1, min(int(limit), 20))}
    if kind:
        params["type"] = kind
    payload = _get("geocode", params)
    if isinstance(payload, list):
        _geo_remember(key, payload)
    return payload


def _rank(places, query):
    """Trie les candidats : nom qui colle, puis France, puis type arret."""
    wanted = _fold(query)

    def score(place):
        name = _fold(place.get("name"))
        value = 0
        if name == wanted:
            value += 100
        elif name.startswith(wanted):
            value += 60
        elif wanted and wanted in name:
            value += 40
        if (place.get("country") or "") in _FRENCH:
            value += 25
        if place.get("type") in ("STOP", "STOPGROUP"):
            value += 15
        if place.get("type") == "ADDRESS":
            value -= 5
        return (-value, name)

    return sorted(places, key=score)


def _place_summary(place):
    return {
        "name": place.get("name"),
        "id": place.get("id"),
        "type": place.get("type"),
        "lat": place.get("lat"),
        "lon": place.get("lon"),
        "country": place.get("country"),
        "areas": [
            a.get("name")
            for a in (place.get("areas") or [])
            if a.get("adminLevel") in (4, 6) and a.get("name")
        ][:2],
    }


def _haversine_km(lat1, lon1, lat2, lon2):
    radius = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = phi2 - phi1
    dlambda = math.radians(lon2 - lon1)
    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    )
    return 2 * radius * math.asin(min(1.0, math.sqrt(a)))


def _point(text):
    """Coordonnees (lat, lon) d'un nom libre, via un geocodage type=PLACE."""
    wanted = _fold(text)
    candidates = _geocode_raw(text, limit=10, kind="PLACE")
    ranked = _rank(candidates or [], text)
    french = [c for c in ranked if (c.get("country") or "") in _FRENCH]
    ranked = french or ranked
    exact = [c for c in ranked if _fold(c.get("name")) == wanted]
    for candidate in exact or ranked[:1]:
        if candidate.get("lat") is not None and candidate.get("lon") is not None:
            return float(candidate["lat"]), float(candidate["lon"])
    return None


def _stop_candidates(text, limit=3, radius_km=30.0):
    """Arrets plausibles pour un nom libre, tries par pertinence.

    Deux requetes de geocodage : le nom seul, puis le nom + ' gare' (les
    grands noms de ville ne rendent pas les gares SNCF tout seuls : 'Paris'
    rend 'Paris Est' et 'Paris-Nord' d'autres feeds, alors que 'Paris gare'
    rend 'Paris Gare du Nord' et 'Paris-Gare-de-Lyon' du feed SNCF).
    Le plan est ensuite tente sur les meilleurs candidats et on garde le plus
    rapide : l'arret le plus proche du centre-ville n'est pas forcement celui
    d'ou part le bon train.
    """
    point = _point(text)
    if point is None:
        return []
    wanted = _fold(text)
    seen = {}
    for query in (text, f"{text} gare"):
        for candidate in _geocode_raw(query, limit=20, kind="STOP") or []:
            lat, lon = candidate.get("lat"), candidate.get("lon")
            ident = candidate.get("id")
            if lat is None or lon is None or not ident or ident in seen:
                continue
            country = candidate.get("country") or ""
            if country and country not in _FRENCH:
                continue
            distance = _haversine_km(point[0], point[1], float(lat), float(lon))
            if distance > radius_km:
                continue
            name = _fold(candidate.get("name"))
            score = 0.0
            if name == wanted:
                score += 3
            elif name.startswith(wanted) or wanted in name:
                score += 1.5
            if str(ident).startswith("fr-horaires-sncf"):
                score += 2.5  # gare SNCF : la ou partent les TGV et TER
            if distance <= 3:
                score += 1
            seen[ident] = {
                "id": str(ident),
                "name": candidate.get("name"),
                "score": score - distance / 30.0,
                "distance_km": round(distance, 1),
            }
    ranked = sorted(seen.values(), key=lambda c: -c["score"])
    return ranked[: max(1, limit)]


def _resolve(place, prefer_country=True):
    """Rend de quoi interroger MOTIS : id d'arret, ou coordonnees explicites."""
    text = str(place or "").strip()
    if not text:
        raise RuntimeError("lieu vide")
    if re.fullmatch(r"\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*", text):
        lat, lon = [x.strip() for x in text.split(",")]
        return f"{float(lat):.5f},{float(lon):.5f}"
    if ":" in text:  # id d'arret ou de lieu rendu par transport_places
        return text
    candidates = _stop_candidates(text, limit=1)
    if candidates:
        return candidates[0]["id"]
    point = _point(text)
    if point:
        return f"{point[0]:.5f},{point[1]:.5f}"
    raise RuntimeError(
        f"lieu introuvable : {text!r} ; essayer transport_places pour trouver "
        "le nom exact d'une gare ou d'un arret"
    )


def _places_to_try(place, limit=2):
    """Liste [(valeur MOTIS, libelle)] a essayer pour un cote de l'itineraire."""
    text = str(place or "").strip()
    if not text:
        raise RuntimeError("lieu vide")
    if re.fullmatch(r"\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*", text):
        return [(re.sub(r"\s", "", text), None)]
    if ":" in text:
        return [(text, None)]
    candidates = _stop_candidates(text, limit=limit)
    if candidates:
        return [(c["id"], c["name"]) for c in candidates]
    point = _point(text)
    if point:
        return [(f"{point[0]:.5f},{point[1]:.5f}", text)]
    raise RuntimeError(
        f"lieu introuvable : {text!r} ; essayer transport_places pour trouver "
        "le nom exact d'une gare ou d'un arret"
    )


# ------------------------------------------------------------- conversions


def _to_utc(when):
    """'2026-12-19 08:00' (heure de Paris) ou ISO avec fuseau -> ISO UTC."""
    text = str(when or "").strip()
    if not text:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    text = text.replace(" ", "T")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        text += "T09:00"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", text):
        try:
            from datetime import datetime, timezone
            from zoneinfo import ZoneInfo

            local = datetime.strptime(text, "%Y-%m-%dT%H:%M").replace(
                tzinfo=ZoneInfo(TZ)
            )
            return local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            raise RuntimeError(f"date illisible : {when!r}") from None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", text):
        return text
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}", text):
        try:
            from datetime import datetime, timezone

            return (
                datetime.fromisoformat(text)
                .astimezone(timezone.utc)
                .strftime("%Y-%m-%dT%H:%M:%SZ")
            )
        except Exception:
            raise RuntimeError(f"date illisible : {when!r}") from None
    raise RuntimeError(
        f"date attendue en AAAA-MM-JJ[THH:MM] (heure de Paris) ou ISO, recu {when!r}"
    )


def _local(iso):
    """ISO UTC de Transitous -> 'HH:MM' heure de Paris."""
    if not iso:
        return None
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo

        stamp = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return stamp.astimezone(ZoneInfo(TZ)).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return str(iso)


def _hhmm(iso):
    local = _local(iso)
    return local[11:] if local and len(local) >= 16 else local


def _line(leg):
    """Etiquette lisible d'un tronçon : 'TGV INOUI 6435', 'Car S63', 'Marche'."""
    short = leg.get("routeShortName") or ""
    long_name = leg.get("routeLongName") or ""
    mode = leg.get("mode") or ""
    labels = {
        "HIGHSPEED_RAIL": "TGV",
        "REGIONAL_RAIL": "TER",
        "REGIONAL": "Car",
        "BUS": "Car",
        "COACH": "Car",
        "SUBWAY": "Metro",
        "TRAM": "Tram",
        "FERRY": "Ferry",
        "LONG_DISTANCE": "Grande ligne",
        "NIGHT_RAIL": "Train de nuit",
        "FUNICULAR": "Funiculaire",
        "WALK": "Marche",
        "BIKE": "Velo",
        "CAR": "Voiture",
    }
    label = labels.get(mode, mode.title() or "?")
    if mode == "WALK":
        return "Marche"
    if short and label.lower() in short.lower():
        return short
    text = " ".join(x for x in (label, short or long_name) if x).strip()
    return text


def _leg_summary(leg, keep_walk=True):
    if leg.get("mode") == "WALK" and not keep_walk:
        return None
    item = {
        "line": _line(leg),
        "mode": leg.get("mode"),
        "from": (leg.get("from") or {}).get("name"),
        "to": (leg.get("to") or {}).get("name"),
        "departure": _hhmm((leg.get("from") or {}).get("departure")),
        "arrival": _hhmm((leg.get("to") or {}).get("arrival")),
        "realTime": bool(leg.get("realTime")),
    }
    tracks = []
    for key, label in (("from", "depart"), ("to", "arrivee")):
        platform = (leg.get(key) or {}).get("track") or (leg.get(key) or {}).get(
            "scheduledTrack"
        )
        if platform:
            tracks.append(f"{label} voie {platform}")
    if tracks:
        item["platforms"] = tracks
    if leg.get("mode") == "WALK":
        distance = leg.get("distance")
        if distance:
            item["meters"] = int(distance)
    if leg.get("headsign"):
        item["headsign"] = leg["headsign"]
    cancelled = any(
        (leg.get(key) or {}).get("cancelled") for key in ("from", "to")
    ) or bool(leg.get("cancelled"))
    if cancelled:
        item["cancelled"] = True
    return item


def _itinerary(it):
    legs = [_leg_summary(leg) for leg in it.get("legs") or []]
    legs = [leg for leg in legs if leg]
    transits = [leg for leg in legs if leg["mode"] != "WALK"]
    return {
        "departure": _local(it.get("startTime")),
        "arrival": _local(it.get("endTime")),
        "duration_min": round((it.get("duration") or 0) / 60),
        "transfers": max(0, len(transits) - 1),
        "modes": sorted({leg["mode"] for leg in transits}),
        "real_time": any(leg["realTime"] for leg in transits),
        "summary": " | ".join(
            f'{leg["line"]} {leg["from"]} {leg["departure"]} > {leg["to"]} {leg["arrival"]}'
            for leg in transits
        ),
        "legs": legs,
    }


def _resolve_stop(place):
    """Id d'arret pour un nom, un id ou 'lat,lon' (via l'arret le plus proche)."""
    text = str(place or "").strip()
    if not text:
        raise RuntimeError("lieu vide")
    if ":" in text:
        return text
    if re.fullmatch(r"\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*", text):
        payload = _get("reverse-geocode", {"place": text.replace(" ", "")})
        candidates = payload if isinstance(payload, list) else [payload]
        for candidate in candidates:
            if candidate and candidate.get("id"):
                return str(candidate["id"])
        raise RuntimeError(f"aucun lieu autour de {text}")
    candidates = _stop_candidates(text, limit=1)
    if candidates:
        return candidates[0]["id"]
    raise RuntimeError(
        f"arret introuvable pour {text!r} ; transport_places donne les noms exacts"
    )


def _plan_payload(origin, destination, when, arrive_by, results, modes, max_transfers):
    when_utc = _to_utc(when)
    params_common = {
        "time": when_utc,
        "arriveBy": "true" if arrive_by else "false",
        "numItineraries": max(1, min(int(results or 3), 8)),
    }
    if modes:
        params_common["mode"] = str(modes).upper()
    if int(max_transfers) >= 0:
        params_common["maxTransfers"] = int(max_transfers)
    best = None
    tried = []
    for origin_value, origin_label in _places_to_try(origin, limit=2):
        for dest_value, dest_label in _places_to_try(destination, limit=2):
            params = dict(params_common)
            params["fromPlace"] = origin_value
            params["toPlace"] = dest_value
            try:
                payload = _get("plan", params)
            except RuntimeError as exc:
                tried.append({"from": origin_value, "to": dest_value, "error": str(exc)[:160]})
                continue
            itineraries = payload.get("itineraries") or []
            tried.append(
                {
                    "from": origin_label or origin_value,
                    "to": dest_label or dest_value,
                    "itineraries": len(itineraries),
                }
            )
            if not itineraries:
                continue
            fastest = min(it.get("duration") or 10**9 for it in itineraries)
            if best is None or fastest < best[0]:
                best = (fastest, itineraries, origin_label, dest_label)
    if best is None:
        return {
            "query": {
                "origin": origin,
                "destination": destination,
                "when_local": _local(when_utc),
                "arrive_by": bool(arrive_by),
                "modes": params_common.get("mode"),
            },
            "itineraries_found": 0,
            "itineraries": [],
            "attempts": tried[:6],
            "note": "horaires theoriques + temps reel quand le feed en publie ; aucun prix",
        }
    _, itineraries, origin_label, dest_label = best
    return {
        "query": {
            "origin": origin,
            "origin_stop": origin_label,
            "destination": destination,
            "destination_stop": dest_label,
            "when_local": _local(when_utc),
            "arrive_by": bool(arrive_by),
            "modes": params_common.get("mode"),
        },
        "itineraries_found": len(itineraries),
        "itineraries": [_itinerary(it) for it in itineraries],
        "note": "horaires theoriques + temps reel quand le feed en publie ; aucun prix",
    }


# ------------------------------------------------------------------- tools


@tool
def transport_status() -> str:
    """Etat du service de calcul d'itineraire (Transitous/MOTIS).

    Smoke test : geocode un lieu connu et verifie que l'API repond. Rend la
    base utilisee, le fuseau et le nombre de centres UCPA connus.
    """
    out = {"base": BASE, "tz": TZ, "state_dir": STATE_DIR}
    try:
        places = _geocode_raw("Paris Gare de Lyon", limit=3)
        out["api_ok"] = bool(places)
        out["sample"] = [_place_summary(p).get("name") for p in places[:3]]
    except RuntimeError as exc:
        out["api_ok"] = False
        out["api_error"] = str(exc)[:200]
    out["ucpa_centers"] = len(UCPA_CENTERS)
    out["sources"] = "GTFS SNCF + cars regionaux + navettes de station + FlixBus/BlaBlaCar Bus"
    return json.dumps(out, ensure_ascii=False, separators=(",", ":"))


@tool
def transport_places(query: str, limit: int = 8) -> str:
    """Cherche des gares, arrets de car, stations ou adresses par nom.

    A appeler avant transport_plan quand un nom est ambigu : 'Moutiers' rend
    plusieurs arrets (car Savoie, BlaBlaCar, IDFM). Les candidats sont tries
    par ressemblance du nom puis par pays FR.
    """
    payload = _geocode_raw(query, limit=limit)
    if not isinstance(payload, list):
        raise RuntimeError("reponse de geocodage illisible")
    ranked = _rank(payload, query)
    return json.dumps(
        {
            "query": query,
            "count": len(ranked),
            "places": [_place_summary(p) for p in ranked],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


@tool
def transport_plan(
    origin: str,
    destination: str,
    when: str = "",
    arrive_by: bool = False,
    results: int = 3,
    modes: str = "",
    max_transfers: int = -1,
) -> str:
    """Itineraire porte a porte train + car + navette, avec correspondances.

    Un seul appel rend le trajet complet : TGV/TER, cars regionaux, navettes
    de station, FlixBus et BlaBlaCar Bus, plus la marche. C'est l'outil a
    utiliser pour rejoindre un centre UCPA, la ou une API ferroviaire seule
    s'arrete a la gare.

    origin / destination : nom libre ('Paris Gare de Lyon', 'Val Thorens'),
    'lat,lon', ou id d'arret rendu par transport_places.
    when : '' = maintenant ; 'AAAA-MM-JJ' (9 h par defaut) ; 'AAAA-MM-JJTHH:MM'
    interprete en heure de Paris ; ISO avec fuseau accepte tel quel.
    arrive_by : True pour arriver avant `when` au lieu de partir apres.
    results : nombre d'itineraires (1 a 8).
    modes : filtre MOTIS optionnel, ex 'TRANSIT,WALK' (seuls les transports en
    commun) ou 'WALK'. Vide = tout.
    max_transfers : -1 = libre, sinon nombre max de correspondances.

    Aucun prix : ni Transitous ni Navitia ne donnent de tarif. Pour un prix,
    passer par SNCF Connect (UC) ou FlixBus (site).
    """
    payload = _plan_payload(
        origin, destination, when, arrive_by, results, modes, max_transfers
    )
    if not payload["itineraries"]:
        payload["hint"] = (
            "aucun itineraire a cette heure : essayer une autre heure, un arret "
            "plus proche (transport_places), ou elargir modes"
        )
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


@tool
def transport_departures(place: str, when: str = "", results: int = 8) -> str:
    """Prochains departs (trains et cars) autour d'un arret.

    Utile pour verifier la derniere navette ou un car unique par jour.
    place : nom libre ou id d'arret ; when : voir transport_plan.
    """
    resolved = _resolve_stop(place)
    stop_id = resolved
    params = {"stopId": stop_id, "time": _to_utc(when), "n": max(1, min(int(results), 20))}
    payload = _get("stoptimes", params)
    rows = []
    for entry in (payload.get("stopTimes") or [])[: params["n"]]:
        place_info = entry.get("place") or {}
        trip_from = entry.get("tripFrom") or {}
        rows.append(
            {
                "line": _line(entry),
                "headsign": entry.get("headsign"),
                "departure": _hhmm(place_info.get("departure")),
                "scheduled": _hhmm(place_info.get("scheduledDeparture")),
                "stop": place_info.get("name"),
                "realTime": bool(entry.get("realTime")),
                "reason": place_info.get("departureTimestampReason"),
                "cancelled": bool(place_info.get("cancelled")),
                "origin": trip_from.get("name"),
            }
        )
    return json.dumps(
        {
            "place": place,
            "stop_id": stop_id,
            "when_local": _local(params["time"]),
            "departures": rows,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


@tool
def transport_ucpa_centers() -> str:
    """Centres UCPA atteignables en train et car, avec l'acces constate.

    Chaque centre porte les coordonnees de l'arret le plus proche, verifiees
    par un itineraire reel depuis Paris. `gap` signale les centres ou le car
    de rabattement manque dans les feeds ouverts.
    """
    rows = []
    for key, center in UCPA_CENTERS.items():
        rows.append(
            {
                "key": key,
                "label": center["label"],
                "lat": center["lat"],
                "lon": center["lon"],
                "access": center["note"],
                "gap": bool(center.get("gap")),
            }
        )
    return json.dumps(
        {"centers": rows, "count": len(rows)},
        ensure_ascii=False,
        separators=(",", ":"),
    )


@tool
def transport_ucpa_plan(
    center: str,
    origin: str = "Paris",
    when: str = "",
    arrive_by: bool = False,
    results: int = 3,
) -> str:
    """Itineraire vers un centre UCPA, par nom ou cle, depuis une ville.

    center : cle ('val-thorens'), nom approche ('Val Thorens', 'serre
    chevalier') ou 'lat,lon'. origin : ville de depart ('Paris', 'Lyon',
    'Bourg-Saint-Maurice'). when : voir transport_plan. arrive_by : True pour
    arriver avant l'heure donnee, ce qui est le cas d'usage (arriver avant le
    debut du sejour).
    """
    text = _fold(center)
    if not text:
        raise RuntimeError("centre vide")
    match = None
    for key, value in UCPA_CENTERS.items():
        haystacks = (_fold(key), _fold(value["label"]))
        if text == _fold(key):
            match = (key, value)
            break
        if any(text in h for h in haystacks) and match is None:
            match = (key, value)
    if match is None:
        if re.fullmatch(r"\s*-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\s*", str(center)):
            return transport_plan(origin, center, when, arrive_by, results)
        known = ", ".join(sorted(k for k, v in UCPA_CENTERS.items() if not v.get("gap")))
        raise RuntimeError(
            f"centre UCPA inconnu : {center!r} ; cles disponibles : {known}"
        )
    key, value = match
    payload = json.loads(
        transport_plan(
            origin,
            f'{value["lat"]},{value["lon"]}',
            when,
            arrive_by,
            results,
        )
    )
    payload["ucpa_center"] = {
        "key": key,
        "label": value["label"],
        "access": value["note"],
        "gap": bool(value.get("gap")),
    }
    if not payload["itineraries"]:
        payload["hint"] = (
            "aucun itineraire : ce centre a un trou de couverture connu"
            if value.get("gap")
            else "aucun itineraire a cette heure : essayer une autre heure de depart"
        )
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
