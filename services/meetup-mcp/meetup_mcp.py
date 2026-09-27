import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

API_URL = os.environ.get("MEETUP_API_URL", "https://api.meetup.com/gql-ext")

EVENT_TYPES = {"online": "ONLINE", "physical": "PHYSICAL", "hybrid": "HYBRID"}

# Sélection standard d'un Event dans toutes les listes (recherches, listes
# de groupe, recommandations). _event_node dépend de ces champs.
EVENT_FIELDS = (
    " id title dateTime eventUrl"
    " group { name urlname }"
    " venue { name city state }"
    " rsvps { totalCount }"
)

mcp = MCPServer("meetup")


def _token():
    """Token OAuth optionnel (la lecture publique n'en a pas besoin).

    Lu à chaque appel : MEETUP_TOKEN_FILE (fichier sops) puis MEETUP_TOKEN.
    """
    path = os.environ.get("MEETUP_TOKEN_FILE", "")
    if path and os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return os.environ.get("MEETUP_TOKEN", "").strip()


def gql(query, variables=None):
    """POST GraphQL sur l'API Meetup ; RuntimeError avec l'erreur brute.

    L'API renvoie HTTP 200 même pour une erreur GraphQL (token expiré,
    champ inconnu) : le tableau `errors` est donc vérifié explicitement.
    """
    payload = {"query": query}
    if variables:
        payload["variables"] = variables
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    token = _token()
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"HTTP {err.code} sur {API_URL} : {err.read().decode()[:500]}") from None
    except urllib.error.URLError as err:
        raise RuntimeError(f"Réseau injoignable ({err.reason}) sur {API_URL}") from None
    errors = body.get("errors") or []
    if errors:
        first = errors[0]
        kind = (first.get("extensions") or {}).get("classification", "?")
        raise RuntimeError(f"Erreur GraphQL Meetup [{kind}] : {first.get('message')}")
    return body.get("data") or {}


def _where(query="", lat=0.0, lon=0.0, radius=0.0):
    """Filtre commun eventSearch/groupSearch. lat/lon sont NonNull côté API."""
    where = {}
    if query:
        where["query"] = query
    where["lat"] = lat
    where["lon"] = lon
    if radius:
        where["radius"] = radius
    return where


def _zoned(value, end=False):
    """'YYYY-MM-DD' -> ZonedDateTime UTC ; une valeur avec 'T' passe telle quelle."""
    if not value:
        return ""
    if "T" in value:
        return value
    return value + ("T23:59:59Z" if end else "T00:00:00Z")


def _edges(conn):
    return (conn or {}).get("edges") or []


def _venue_str(venue):
    if not venue:
        return None
    parts = [venue.get("name"), venue.get("city"), venue.get("state")]
    return ", ".join([p for p in parts if p]) or None


def _event_node(node):
    group = node.get("group") or {}
    return {
        "id": node.get("id"),
        "titre": node.get("title"),
        "date": node.get("dateTime"),
        "url": node.get("eventUrl"),
        "groupe": group.get("name"),
        "urlname": group.get("urlname"),
        "lieu": _venue_str(node.get("venue")),
        "rsvps": (node.get("rsvps") or {}).get("totalCount"),
    }


def _group_node(node):
    return {
        "id": node.get("id"),
        "nom": node.get("name"),
        "urlname": node.get("urlname"),
        "lien": node.get("link"),
        "membres": (node.get("memberships") or {}).get("totalCount"),
        "ville": node.get("city"),
        "pays": node.get("country"),
    }


def _connection(conn, mapper, key):
    conn = conn or {}
    out = {
        "total": conn.get("totalCount"),
        key: [mapper(e.get("node") or {}) for e in _edges(conn)],
    }
    page = conn.get("pageInfo") or {}
    if page.get("endCursor"):
        out["curseur_suivant"] = page["endCursor"]
    return out


def _date_key(event):
    try:
        dt = datetime.fromisoformat(event.get("date") or "")
    except ValueError:
        return datetime.max.replace(tzinfo=timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


@mcp.tool()
def status() -> dict:
    """État du serveur Meetup : API joignable, mode d'auth, compte lié.

    Tourne sans credentials en mode public (recherche et consultation des
    données publiques uniquement). Si un token OAuth est configuré, vérifie
    aussi le compte membre associé. Sert de test de vie du serveur.
    """
    token = _token()
    data = gql("query { topicCategories { edges { node { id } } } }")
    out = {
        "endpoint": API_URL,
        "mode": "public (sans token)" if not token else "token configuré",
        "categories_topics": len(_edges(data.get("topicCategories"))),
    }
    if token:
        me = gql("query { self { id name username } }").get("self")
        out["compte"] = me if me else "token refusé (self = null)"
    return out


@mcp.tool()
def search_events(
    lat: float,
    lon: float,
    query: str = "",
    radius: float = 25.0,
    event_type: str = "",
    start_date: str = "",
    end_date: str = "",
    sort: str = "relevance",
    limit: int = 10,
    after: str = "",
) -> dict:
    """Cherche des events Meetup publics par mots-clés autour d'un point.

    La recherche Meetup est sémantique : query approxime un thème plutôt
    qu'un match littéral. lat/lon obligatoires (géocoder la ville avant si
    besoin) ; radius en miles. event_type : online, physical ou hybrid.
    start_date/end_date bornent les dates ("YYYY-MM-DD", interprété en UTC,
    ou ZonedDateTime complet). sort : "relevance" (défaut) ou "datetime"
    (chronologique, tri refait côté serveur). limit 1-50. after : reprendre
    à « curseur_suivant » d'un appel précédent.
    """
    where = _where(query, lat, lon, radius)
    if event_type:
        key = event_type.strip().lower()
        if key not in EVENT_TYPES:
            return {"erreur": "event_type attendu : online, physical ou hybrid"}
        where["eventType"] = EVENT_TYPES[key]
    start = _zoned(start_date)
    end = _zoned(end_date, end=True)
    if start:
        where["startDateRange"] = start
    if end:
        where["endDateRange"] = end
    if sort not in ("relevance", "datetime"):
        return {"erreur": "sort attendu : relevance ou datetime"}
    order = ", sort: {sortField: DATETIME, sortOrder: ASC}" if sort == "datetime" else ""
    variables = {"filter": where, "first": max(1, min(limit, 50))}
    if after:
        variables["after"] = after
    data = gql(
        "query($filter: EventSearchFilter!, $first: Int, $after: String) {"
        " eventSearch(filter: $filter, first: $first, after: $after" + order + ") {"
        " totalCount pageInfo { endCursor }"
        " edges { node {" + EVENT_FIELDS + "} } } }",
        variables,
    )
    out = _connection(data.get("eventSearch"), _event_node, "events")
    if sort == "datetime":
        out["events"].sort(key=_date_key)
    return out


@mcp.tool()
def get_event(event_id: str) -> dict:
    """Détail complet d'un event public par son id (ex. "316297665").

    Inclut dates, lieu, groupe, hôtes, topics, frais, photo, nombre de
    RSVP. La liste nominative des participants n'est pas publique.
    """
    data = gql(
        "query($id: ID!) { event(id: $id) {"
        " id title description dateTime endTime duration eventUrl"
        " eventType status"
        " venue { name address city state lat lon }"
        " group { id name urlname link }"
        " eventHosts { name member { id name } }"
        " topics { edges { node { name id } } }"
        " feeSettings { amount currency }"
        " featuredEventPhoto { highResUrl }"
        " rsvps { totalCount }"
        " } }",
        {"id": event_id},
    )
    event = data.get("event")
    if not event:
        return {"trouve": False, "event_id": event_id}
    venue = event.get("venue") or {}
    group = event.get("group") or {}
    return {
        "id": event.get("id"),
        "titre": event.get("title"),
        "description": (event.get("description") or "")[:3000],
        "date": event.get("dateTime"),
        "fin": event.get("endTime"),
        "duree": event.get("duration"),
        "url": event.get("eventUrl"),
        "type": event.get("eventType"),
        "statut": event.get("status"),
        "lieu": {
            "nom": venue.get("name"),
            "adresse": venue.get("address"),
            "ville": venue.get("city"),
            "region": venue.get("state"),
            "lat": venue.get("lat"),
            "lon": venue.get("lon"),
        },
        "groupe": {
            "id": group.get("id"),
            "nom": group.get("name"),
            "urlname": group.get("urlname"),
            "lien": group.get("link"),
        },
        "hotes": [h.get("name") for h in (event.get("eventHosts") or [])],
        "topics": [(t.get("node") or {}).get("name") for t in _edges(event.get("topics"))],
        "frais": event.get("feeSettings"),
        "photo": (event.get("featuredEventPhoto") or {}).get("highResUrl"),
        "rsvps": (event.get("rsvps") or {}).get("totalCount"),
    }


@mcp.tool()
def get_events(event_ids: list[str]) -> list:
    """Résumé de plusieurs events à partir de leurs ids (max 20).

    Pour revérifier d'un coup des events déjà repérés (titre, date, url,
    groupe, lieu, rsvps) sans un appel par id.
    """
    ids = [str(i) for i in event_ids][:20]
    data = gql(
        "query($where: EventSearch!) { events(where: $where) {" + EVENT_FIELDS + "} }",
        {"where": {"ids": ids}},
    )
    return [_event_node(n) for n in (data.get("events") or [])]


@mcp.tool()
def search_groups(
    lat: float,
    lon: float,
    query: str = "",
    radius: float = 25.0,
    limit: int = 10,
    after: str = "",
) -> dict:
    """Cherche des groupes Meetup autour d'un point (mots-clés optionnels).

    lat/lon obligatoires, radius en miles. after : curseur d'une page
    précédente (« curseur_suivant »).
    """
    where = _where(query, lat, lon, radius)
    variables = {"filter": where, "first": max(1, min(limit, 50))}
    if after:
        variables["after"] = after
    data = gql(
        "query($filter: GroupSearchFilter!, $first: Int, $after: String) {"
        " groupSearch(filter: $filter, first: $first, after: $after) {"
        " totalCount pageInfo { endCursor }"
        " edges { node { id name urlname link memberships { totalCount } city country } } } }",
        variables,
    )
    return _connection(data.get("groupSearch"), _group_node, "groupes")


@mcp.tool()
def get_group(urlname: str) -> dict:
    """Fiche d'un groupe par son urlname (ex. "nyhackr") + 5 prochains events.

    urlname : le segment d'URL meetup.com/<urlname> ; aussi renvoyé par
    search_groups et par les events (champ urlname).
    """
    data = gql(
        "query($urlname: String!) { groupByUrlname(urlname: $urlname) {"
        " id name urlname description link"
        " city state country lat lon timezone foundedDate"
        " memberships { totalCount }"
        " keyGroupPhoto { highResUrl }"
        " organizer { id name }"
        " events(first: 5) { edges { node {" + EVENT_FIELDS + "} } }"
        " } }",
        {"urlname": urlname},
    )
    group = data.get("groupByUrlname")
    if not group:
        return {"trouve": False, "urlname": urlname}
    return {
        "id": group.get("id"),
        "nom": group.get("name"),
        "urlname": group.get("urlname"),
        "description": (group.get("description") or "")[:2000],
        "lien": group.get("link"),
        "ville": group.get("city"),
        "region": group.get("state"),
        "pays": group.get("country"),
        "lat": group.get("lat"),
        "lon": group.get("lon"),
        "timezone": group.get("timezone"),
        "cree_le": group.get("foundedDate"),
        "membres": (group.get("memberships") or {}).get("totalCount"),
        "photo": (group.get("keyGroupPhoto") or {}).get("highResUrl"),
        "organisateur": (group.get("organizer") or {}).get("name"),
        "prochains_events": [_event_node(e.get("node") or {}) for e in _edges(group.get("events"))],
    }


@mcp.tool()
def list_group_events(urlname: str, status: str = "upcoming", limit: int = 10) -> dict:
    """Events d'un groupe : status "upcoming" (défaut) ou "past".

    "past" liste les plus anciens d'abord (ordre Meetup, non triable).
    """
    if status not in ("upcoming", "past"):
        return {"erreur": "status attendu : upcoming ou past"}
    filt = ", filter: {status: PAST}" if status == "past" else ""
    data = gql(
        "query($urlname: String!, $first: Int) { groupByUrlname(urlname: $urlname) {"
        " name urlname link"
        " events(first: $first" + filt + ") { edges { node {" + EVENT_FIELDS + "} } }"
        " } }",
        {"urlname": urlname, "first": max(1, min(limit, 50))},
    )
    group = data.get("groupByUrlname")
    if not group:
        return {"trouve": False, "urlname": urlname}
    return {
        "groupe": group.get("name"),
        "urlname": group.get("urlname"),
        "lien": group.get("link"),
        "statut": status,
        "events": [_event_node(e.get("node") or {}) for e in _edges(group.get("events"))],
    }


@mcp.tool()
def recommended_events(lat: float, lon: float, radius: float = 25.0, limit: int = 10) -> dict:
    """Events recommandés par Meetup autour d'un point, sans mots-clés.

    lat/lon obligatoires ; radius en miles. Pour une recherche par thème,
    passer par search_events.
    """
    where = {"lat": lat, "lon": lon}
    if radius:
        where["radius"] = radius
    data = gql(
        "query($filter: RecommendedEventsFilter!, $first: Int) {"
        " recommendedEvents(filter: $filter, first: $first) {"
        " totalCount pageInfo { endCursor }"
        " edges { node {" + EVENT_FIELDS + "} } } }",
        {"filter": where, "first": max(1, min(limit, 50))},
    )
    return _connection(data.get("recommendedEvents"), _event_node, "events")


@mcp.tool()
def recommended_groups(lat: float, lon: float, radius: float = 25.0, limit: int = 10) -> dict:
    """Groupes recommandés par Meetup autour d'un point, sans mots-clés."""
    where = {"lat": lat, "lon": lon}
    if radius:
        where["radius"] = radius
    data = gql(
        "query($filter: RecommendedGroupsFilter!, $first: Int) {"
        " recommendedGroups(filter: $filter, first: $first) {"
        " totalCount edges { node { id name urlname link memberships { totalCount } city country } } } }",
        {"filter": where, "first": max(1, min(limit, 50))},
    )
    return _connection(data.get("recommendedGroups"), _group_node, "groupes")


@mcp.tool()
def suggest_topics(query: str, limit: int = 10) -> list:
    """Suggère des topics Meetup réels pour un mot-clé (id, nom, urlkey).

    Utile pour préciser un thème de recherche ou qualifier un groupe.
    """
    data = gql(
        "query($query: String!, $first: Int) {"
        " suggestTopics(query: $query, first: $first) {"
        " edges { node { id name urlkey } } } }",
        {"query": query, "first": max(1, min(limit, 25))},
    )
    return [(e.get("node") or {}) for e in _edges(data.get("suggestTopics"))]


@mcp.tool()
def list_topic_categories() -> list:
    """Catégories de topics Meetup (id + nom), pour situer les grands thèmes."""
    data = gql("query { topicCategories { edges { node { id name } } } }")
    return [(e.get("node") or {}) for e in _edges(data.get("topicCategories"))]


if __name__ == "__main__":
    mcp.run()
