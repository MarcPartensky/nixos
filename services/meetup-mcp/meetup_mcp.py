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

# Standard selection of an Event in all lists (searches, group
# lists, recommendations). _event_node depends on these fields.
EVENT_FIELDS = (
    " id title dateTime eventUrl"
    " group { name urlname }"
    " venue { name city state }"
    " rsvps { totalCount }"
)

mcp = MCPServer("meetup")


def _token():
    """Optional OAuth token (public reading does not need one).

    Read on each call: MEETUP_TOKEN_FILE (sops file) then MEETUP_TOKEN.
    """
    path = os.environ.get("MEETUP_TOKEN_FILE", "")
    if path and os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return os.environ.get("MEETUP_TOKEN", "").strip()


def gql(query, variables=None):
    """POST GraphQL on the Meetup API; RuntimeError with the raw error.

    The API returns HTTP 200 even for a GraphQL error (expired token,
    unknown field): the `errors` array is therefore checked explicitly.
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
        raise RuntimeError(f"HTTP {err.code} on {API_URL}: {err.read().decode()[:500]}") from None
    except urllib.error.URLError as err:
        raise RuntimeError(f"Network unreachable ({err.reason}) at {API_URL}") from None
    errors = body.get("errors") or []
    if errors:
        first = errors[0]
        kind = (first.get("extensions") or {}).get("classification", "?")
        raise RuntimeError(f"Meetup GraphQL error [{kind}]: {first.get('message')}")
    return body.get("data") or {}


def _where(query="", lat=0.0, lon=0.0, radius=0.0):
    """Common filter for eventSearch/groupSearch. lat/lon are NonNull on the API side."""
    where = {}
    if query:
        where["query"] = query
    where["lat"] = lat
    where["lon"] = lon
    if radius:
        where["radius"] = radius
    return where


def _zoned(value, end=False):
    """'YYYY-MM-DD' -> ZonedDateTime UTC; a value with 'T' passes through as-is."""
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
    """Status of the Meetup server: API reachable, auth mode, linked account.

    Runs without credentials in public mode (search and consultation of
    public data only). If an OAuth token is configured, it also checks
    the associated member account. Serves as a liveness test of the server.
    """
    token = _token()
    data = gql("query { topicCategories { edges { node { id } } } }")
    out = {
        "endpoint": API_URL,
        "mode": "public (no token)" if not token else "token configured",
        "categories_topics": len(_edges(data.get("topicCategories"))),
    }
    if token:
        me = gql("query { self { id name username } }").get("self")
        out["compte"] = me if me else "token refused (self = null)"
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
    """Search public Meetup events by keywords around a point.

    Meetup search is semantic: query approximates a theme rather
    than a literal match. lat/lon mandatory (geocode the city first if
    needed); radius in miles. event_type: online, physical or hybrid.
    start_date/end_date bound the dates ("YYYY-MM-DD", interpreted as UTC,
    or a full ZonedDateTime). sort: "relevance" (default) or "datetime"
    (chronological, sort redone server-side). limit 1-50. after: resume
    at "curseur_suivant" of a previous call.
    """
    where = _where(query, lat, lon, radius)
    if event_type:
        key = event_type.strip().lower()
        if key not in EVENT_TYPES:
            return {"erreur": "event_type expected: online, physical or hybrid"}
        where["eventType"] = EVENT_TYPES[key]
    start = _zoned(start_date)
    end = _zoned(end_date, end=True)
    if start:
        where["startDateRange"] = start
    if end:
        where["endDateRange"] = end
    if sort not in ("relevance", "datetime"):
        return {"erreur": "sort expected: relevance or datetime"}
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
    """Full detail of a public event by its id (e.g. "316297665").

    Includes dates, venue, group, hosts, topics, fees, photo, number of
    RSVPs. The nominal list of participants is not public.
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
    """Summary of several events from their ids (max 20).

    To re-check at once events already spotted (titre, date, url,
    groupe, lieu, rsvps) without one call per id.
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
    """Search Meetup groups around a point (optional keywords).

    lat/lon mandatory, radius in miles. after: cursor of a
    previous page ("curseur_suivant").
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
    """Details of a group by its urlname (e.g. "nyhackr") + 5 next events.

    urlname: the URL segment meetup.com/<urlname>; also returned by
    search_groups and by the events (field urlname).
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
    """Events of a group: status "upcoming" (default) or "past".

    "past" lists the oldest first (Meetup order, not sortable).
    """
    if status not in ("upcoming", "past"):
        return {"erreur": "status expected: upcoming or past"}
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
    """Events recommended by Meetup around a point, without keywords.

    lat/lon mandatory; radius in miles. For a search by theme,
    use search_events.
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
    """Groups recommended by Meetup around a point, without keywords."""
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
    """Suggests real Meetup topics for a keyword (id, nom, urlkey).

    Useful to refine a search theme or to qualify a group.
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
    """Meetup topic categories (id + nom), to situate the main themes."""
    data = gql("query { topicCategories { edges { node { id name } } } }")
    return [(e.get("node") or {}) for e in _edges(data.get("topicCategories"))]


if __name__ == "__main__":
    mcp.run()
