"""Transport tools (train + coach + shuttle) for mcp-host.

Why this module: to reach a UCPA center, the SNCF API (Navitia) is not
enough. It only knows rail: the last leg (regional coach,
resort shuttle, intercity coach) is missing, and that is exactly the one that
serves the resorts. An MCP server backed by Navitia alone therefore forces you to
stitch train and coach back together by hand.

Here everything goes through Transitous (https://transitous.org), a public
MOTIS instance that aggregates the GTFS of all of Europe: SNCF timetables (feed
fr-horaires-sncf), regional coaches (Savoie, Hautes-Alpes, Occitanie...),
resort shuttles (Bourg-Saint-Maurice, Tignes, Val d'Isere), FlixBus and
BlaBlaCar Bus. A single call returns the door-to-door itinerary, train and coach
mixed, with the connections computed.

Why no local graph (OpenTripPlanner / self-hosted MOTIS): the
whole-France graph weighs several GB of RAM and costs hours of CPU to
build, for an identical result. Here the local cost is zero: a JSON
GET of ~1 s, no dependency outside the stdlib, no graph cache.

Limits measured on 18/11/2026:
- No price. Neither Transitous nor Navitia sell tickets; SNCF Connect
  prices are behind a private unofficial API.
- Partial real time: each feed exposes GTFS-RT or not. The
  realTime field of each leg says what is confirmed (NO_RT_DATA otherwise).
- Coverage gap observed from Paris: Les Orres 1650 and Val Cenis
  Lanslebourg return no itinerary (feeder coach missing from the
  feeds) whereas 18 other UCPA centers work.

Env: TRANSPORT_BASE (default https://api.transitous.org/api/v1),
TRANSPORT_TIMEOUT (default 40), TRANSPORT_STATE_DIR (geocoding cache),
TRANSPORT_TZ (default Europe/Paris).
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
except Exception:  # test outside mcp-host: neutral decorator

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

# Transitous requires an identifiable UA; never marc's name in it.
UA = os.environ.get("TRANSPORT_UA", "hermes-transport-mcp/1.0 (+self-hosted)")

# Reachable UCPA centers, coordinates of the nearest stop verified
# by a real itinerary from Paris on 18/11/2026. `note` says what was
# observed, `gap` flags a center where the feeder coach is missing.
UCPA_CENTERS = {
    "val-thorens": {
        "label": "UCPA Val Thorens",
        "lat": 45.29965,
        "lon": 6.569263,
        "note": "stop 'VAL THORENS UCPA' of the regional Savoie coach (S63 from Moutiers)",
    },
    "valloire": {
        "label": "UCPA Valloire",
        "lat": 45.15585,
        "lon": 6.42073,
        "note": "stop 'VALLOIRE UCPA' of the regional Savoie coach (S40 from Saint-Michel)",
    },
    "val-d-isere": {
        "label": "UCPA Val d'Isere",
        "lat": 45.459877,
        "lon": 6.965673,
        "note": "coach S82 from Bourg-Saint-Maurice",
    },
    "tignes": {
        "label": "UCPA Tignes",
        "lat": 45.4694,
        "lon": 6.9049,
        "note": "coach S83 from Bourg-Saint-Maurice",
    },
    "les-arcs": {
        "label": "UCPA Les Arcs (Arc 1600)",
        "lat": 45.59905,
        "lon": 6.79973,
        "note": "funicular from Bourg-Saint-Maurice (station in the graph)",
    },
    "la-plagne": {
        "label": "UCPA La Plagne Le France",
        "lat": 45.506763,
        "lon": 6.675743,
        "note": "coach S71 from Aime-la-Plagne; coordinates of Plagne Centre, center ~1 km away",
    },
    "chamonix": {
        "label": "UCPA Chamonix",
        "lat": 45.92277,
        "lon": 6.87363,
        "note": "TGV to Saint-Gervais or Sallanches, then BlaBlaCar Bus / TER",
    },
    "argentiere": {
        "label": "UCPA Argentiere (Vallee du Mont-Blanc)",
        "lat": 45.981944,
        "lon": 6.926484,
        "note": "TER Chamonix then walk; the BlaBlaCar Bus coach stops at Chamonix",
    },
    "les-contamines": {
        "label": "UCPA Les Contamines",
        "lat": 45.82238,
        "lon": 6.72685,
        "note": "coach Y84 from Sallanches / Saint-Gervais",
    },
    "flaine": {
        "label": "UCPA Flaine",
        "lat": 46.005558,
        "lon": 6.692669,
        "note": "LCFE shuttle from Cluses (stop 'FLAINE - FORUM')",
    },
    "pralognan": {
        "label": "UCPA Pralognan",
        "lat": 45.388622,
        "lon": 6.716409,
        "note": "coach S66 from Moutiers",
    },
    "les-orres": {
        "label": "UCPA Les Orres",
        "lat": 44.49429,
        "lon": 6.55675,
        "note": "feeder coach missing from the feeds: 0 itineraries measured, aim for Embrun then local coach",
        "gap": True,
    },
    "les-deux-alpes": {
        "label": "UCPA Les Deux Alpes (Venosc)",
        "lat": 45.0105,
        "lon": 6.1246,
        "note": "coach from Grenoble then Venosc; coordinates of the resort (the Venosc cable car is not in the graph)",
    },
    "val-cenis": {
        "label": "UCPA Val Cenis",
        "lat": 45.28539,
        "lon": 6.8755,
        "note": "feeder coach missing from the feeds: 0 itineraries measured, aim for Modane then local coach",
        "gap": True,
    },
    "serre-chevalier": {
        "label": "UCPA Serre Chevalier (Monetier)",
        "lat": 44.9763,
        "lon": 6.507302,
        "note": "TER to Briancon then ZOU coach / local lines",
    },
    "saint-lary": {
        "label": "UCPA Saint-Lary-Soulan",
        "lat": 42.818394,
        "lon": 0.322091,
        "note": "train to Lannemezan or Tarbes then regional coach",
    },
    "guchen": {
        "label": "UCPA Guchen (Vallee de Saint-Lary)",
        "lat": 42.86289,
        "lon": 0.338455,
        "note": "same access as Saint-Lary, upstream stop",
    },
    "valmeinier": {
        "label": "UCPA Valmeinier",
        "lat": 45.17964,
        "lon": 6.48492,
        "note": "coach S41 from Saint-Michel - Valloire",
    },
    "chapelle-vercors": {
        "label": "UCPA La Chapelle-en-Vercors",
        "lat": 44.964764,
        "lon": 5.414576,
        "note": "TGV to Valence then coach D05",
    },
    "vallouise": {
        "label": "UCPA Vallouise (Ecrins)",
        "lat": 44.84532,
        "lon": 6.4899,
        "note": "TER to Briancon then coach L1",
    },
}

_FRENCH = {"FR", "MC"}


# ------------------------------------------------------------------ network


def _get(path, params=None):
    """GET JSON from Transitous. Raises RuntimeError with the error body."""
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
        raise RuntimeError(f"Transitous HTTP {exc.code} on /{path}: {detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Transitous unreachable (/{path}): {exc.reason}") from None
    except ValueError:
        raise RuntimeError(f"Transitous /{path}: non-JSON response") from None


def _fold(text):
    """Lowercase without accents, to compare 'Moutiers' and 'Moutiers'."""
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
    """Sorts the candidates: matching name, then France, then stop type."""
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
    """Coordinates (lat, lon) of a free-form name, via a type=PLACE geocoding."""
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
    """Plausible stops for a free-form name, sorted by relevance.

    Two geocoding requests: the name alone, then the name + ' gare' (large
    city names do not return SNCF stations by themselves: 'Paris'
    returns 'Paris Est' and 'Paris-Nord' from other feeds, whereas 'Paris gare'
    returns 'Paris Gare du Nord' and 'Paris-Gare-de-Lyon' from the SNCF feed).
    The plan is then tried on the best candidates and the fastest is kept:
    the stop closest to the city center is not necessarily the one
    the right train departs from.
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
                score += 2.5  # SNCF station: where the TGV and TER depart from
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
    """Returns what is needed to query MOTIS: stop id, or explicit coordinates."""
    text = str(place or "").strip()
    if not text:
        raise RuntimeError("empty place")
    if re.fullmatch(r"\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*", text):
        lat, lon = [x.strip() for x in text.split(",")]
        return f"{float(lat):.5f},{float(lon):.5f}"
    if ":" in text:  # stop or place id returned by transport_places
        return text
    candidates = _stop_candidates(text, limit=1)
    if candidates:
        return candidates[0]["id"]
    point = _point(text)
    if point:
        return f"{point[0]:.5f},{point[1]:.5f}"
    raise RuntimeError(
        f"place not found: {text!r}; try transport_places to find "
        "the exact name of a station or stop"
    )


def _places_to_try(place, limit=2):
    """List of [(MOTIS value, label)] to try for one side of the itinerary."""
    text = str(place or "").strip()
    if not text:
        raise RuntimeError("empty place")
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
        f"place not found: {text!r}; try transport_places to find "
        "the exact name of a station or stop"
    )


# ------------------------------------------------------------- conversions


def _to_utc(when):
    """'2026-12-19 08:00' (Paris time) or ISO with timezone -> ISO UTC."""
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
            raise RuntimeError(f"unreadable date: {when!r}") from None
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
            raise RuntimeError(f"unreadable date: {when!r}") from None
    raise RuntimeError(
        f"date expected as YYYY-MM-DD[THH:MM] (Paris time) or ISO, got {when!r}"
    )


def _local(iso):
    """Transitous ISO UTC -> 'HH:MM' Paris time."""
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
    """Readable label of a leg: 'TGV INOUI 6435', 'Coach S63', 'Walk'."""
    short = leg.get("routeShortName") or ""
    long_name = leg.get("routeLongName") or ""
    mode = leg.get("mode") or ""
    labels = {
        "HIGHSPEED_RAIL": "TGV",
        "REGIONAL_RAIL": "TER",
        "REGIONAL": "Coach",
        "BUS": "Coach",
        "COACH": "Coach",
        "SUBWAY": "Metro",
        "TRAM": "Tram",
        "FERRY": "Ferry",
        "LONG_DISTANCE": "Long distance",
        "NIGHT_RAIL": "Night train",
        "FUNICULAR": "Funicular",
        "WALK": "Walk",
        "BIKE": "Bike",
        "CAR": "Car",
    }
    label = labels.get(mode, mode.title() or "?")
    if mode == "WALK":
        return "Walk"
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
    for key, label in (("from", "depart"), ("to", "arrival")):
        platform = (leg.get(key) or {}).get("track") or (leg.get(key) or {}).get(
            "scheduledTrack"
        )
        if platform:
            tracks.append(f"{label} track {platform}")
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
    """Stop id for a name, an id or 'lat,lon' (via the nearest stop)."""
    text = str(place or "").strip()
    if not text:
        raise RuntimeError("empty place")
    if ":" in text:
        return text
    if re.fullmatch(r"\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*", text):
        payload = _get("reverse-geocode", {"place": text.replace(" ", "")})
        candidates = payload if isinstance(payload, list) else [payload]
        for candidate in candidates:
            if candidate and candidate.get("id"):
                return str(candidate["id"])
        raise RuntimeError(f"no place around {text}")
    candidates = _stop_candidates(text, limit=1)
    if candidates:
        return candidates[0]["id"]
    raise RuntimeError(
        f"stop not found for {text!r}; transport_places gives the exact names"
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
            "note": "theoretical timetables + real time when the feed publishes it; no price",
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
        "note": "theoretical timetables + real time when the feed publishes it; no price",
    }


# ------------------------------------------------------------------- tools


@tool
def transport_status() -> str:
    """Status of the itinerary computation service (Transitous/MOTIS).

    Smoke test: geocodes a known place and checks that the API responds. Returns the
    base used, the timezone and the number of known UCPA centers.
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
    out["sources"] = "GTFS SNCF + regional coaches + resort shuttles + FlixBus/BlaBlaCar Bus"
    return json.dumps(out, ensure_ascii=False, separators=(",", ":"))


@tool
def transport_places(query: str, limit: int = 8) -> str:
    """Searches stations, coach stops, resorts or addresses by name.

    Call before transport_plan when a name is ambiguous: 'Moutiers' returns
    several stops (Savoie coach, BlaBlaCar, IDFM). The candidates are sorted
    by name similarity then by country FR.
    """
    payload = _geocode_raw(query, limit=limit)
    if not isinstance(payload, list):
        raise RuntimeError("unreadable geocoding response")
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
    """Door-to-door train + coach + shuttle itinerary, with connections.

    A single call returns the full trip: TGV/TER, regional coaches, resort
    shuttles, FlixBus and BlaBlaCar Bus, plus walking. This is the tool to
    use to reach a UCPA center, where a rail API alone
    stops at the station.

    origin / destination: free-form name ('Paris Gare de Lyon', 'Val Thorens'),
    'lat,lon', or a stop id returned by transport_places.
    when: '' = now; 'YYYY-MM-DD' (9:00 by default); 'YYYY-MM-DDTHH:MM'
    interpreted in Paris time; ISO with timezone accepted as is.
    arrive_by: True to arrive before `when` instead of departing after.
    results: number of itineraries (1 to 8).
    modes: optional MOTIS filter, e.g. 'TRANSIT,WALK' (public transport
    only) or 'WALK'. Empty = everything.
    max_transfers: -1 = free, otherwise max number of connections.

    No price: neither Transitous nor Navitia give a fare. For a price,
    go through SNCF Connect (UC) or FlixBus (site).
    """
    payload = _plan_payload(
        origin, destination, when, arrive_by, results, modes, max_transfers
    )
    if not payload["itineraries"]:
        payload["hint"] = (
            "no itinerary at this time: try another time, a closer "
            "stop (transport_places), or widen modes"
        )
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


@tool
def transport_departures(place: str, when: str = "", results: int = 8) -> str:
    """Next departures (trains and coaches) around a stop.

    Useful to check the last shuttle or a coach that runs once a day.
    place: free-form name or stop id; when: see transport_plan.
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
    """UCPA centers reachable by train and coach, with the observed access.

    Each center carries the coordinates of the nearest stop, verified
    by a real itinerary from Paris. `gap` flags the centers where the feeder
    coach is missing from the open feeds.
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
    """Itinerary to a UCPA center, by name or key, from a city.

    center: key ('val-thorens'), approximate name ('Val Thorens', 'serre
    chevalier') or 'lat,lon'. origin: departure city ('Paris', 'Lyon',
    'Bourg-Saint-Maurice'). when: see transport_plan. arrive_by: True to
    arrive before the given time, which is the use case (arrive before the
    start of the stay).
    """
    text = _fold(center)
    if not text:
        raise RuntimeError("empty center")
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
            f"unknown UCPA center: {center!r}; available keys: {known}"
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
            "no itinerary: this center has a known coverage gap"
            if value.get("gap")
            else "no itinerary at this time: try another departure time"
        )
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
