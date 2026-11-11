"""Serveur MCP Shlink : pilote l'API REST v3 d'une instance self-hosted.

Écrit de zéro pour ce flake plutôt que d'emballer un connecteur tiers :
l'API Shlink est documentée par une spec OpenAPI complète
(https://api-spec.shlink.io), donc la couverture maximale tient en un
passthrough générique (`shlink_request`) plus des outils typés pour les
opérations courantes.

Politique d'écriture : SHLINK_ALLOW_WRITES=1 active les outils mutants, mais
chaque écriture exige en plus `confirm=True` (sinon l'outil renvoie un aperçu
de la requête sans rien envoyer). Les lectures ne demandent rien.

Auth : clé d'API Shlink relue à chaque appel depuis SHLINK_API_KEY_FILE
(secret sops) ou SHLINK_API_KEY.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

from mcp.server.fastmcp import FastMCP

BASE_URL = os.environ.get("SHLINK_URL", "http://127.0.0.1:8097").rstrip("/")
KEY_FILE = os.environ.get("SHLINK_API_KEY_FILE", "")
ALLOW_WRITES = os.environ.get("SHLINK_ALLOW_WRITES", "0") == "1"
TIMEOUT = float(os.environ.get("SHLINK_TIMEOUT", "30"))

mcp = FastMCP("shlink")


def _api_key():
    key = ""
    if KEY_FILE:
        try:
            with open(KEY_FILE) as f:
                key = f.read().strip()
        except OSError:
            key = ""
    key = key or os.environ.get("SHLINK_API_KEY", "")
    if not key:
        raise RuntimeError(
            "clé d'API Shlink absente : %s illisible et SHLINK_API_KEY vide"
            % (KEY_FILE or "<SHLINK_API_KEY_FILE non défini>")
        )
    return key


def _call(method, path, query=None, body=None):
    """Appelle l'API REST v3 et rend un dict JSON (ou une erreur lisible)."""
    url = BASE_URL + "/rest/v3" + path
    clean = {k: v for k, v in (query or {}).items() if v is not None}
    if clean:
        url += "?" + urllib.parse.urlencode(clean, doseq=True)
    data = None
    headers = {"Accept": "application/json", "X-Api-Key": _api_key()}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read().decode("utf-8", "replace")
            return {"status": r.status, "body": json.loads(raw) if raw else {}}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = raw[:2000]
        return {"status": e.code, "error": payload}
    except urllib.error.URLError as e:
        return {"status": 0, "error": "injoignable: %s" % e.reason}


def _write_guard(action, payload):
    if not ALLOW_WRITES:
        return {
            "dry_run": True,
            "reason": "SHLINK_ALLOW_WRITES=0 : écritures désactivées "
                      "dans la config du serveur MCP",
            "action": action,
            "payload": payload,
        }
    return None


@mcp.tool()
def shlink_health() -> dict:
    """État de santé de l'instance Shlink (GET /rest/health)."""
    return _call("GET", "/health")


@mcp.tool()
def shlink_list_short_urls(
    search_term: str | None = None,
    tags: list[str] | None = None,
    exclude_tags: list[str] | None = None,
    domain: str | None = None,
    order_by: str | None = None,
    page: int = 1,
    items_per_page: int = 20,
) -> dict:
    """Liste les liens courts. search_term filtre sur l'URL et le slug."""
    query = {
        "searchTerm": search_term,
        "domain": domain,
        "orderBy": order_by,
        "page": page,
        "itemsPerPage": items_per_page,
    }
    if tags:
        query["tags[]"] = tags
    if exclude_tags:
        query["excludeTags[]"] = exclude_tags
    return _call("GET", "/short-urls", query)


@mcp.tool()
def shlink_get_short_url(short_code: str, domain: str | None = None) -> dict:
    """Détail d'un lien court (cible, tags, dates, règles propres)."""
    return _call("GET", "/short-urls/" + short_code, {"domain": domain})


@mcp.tool()
def shlink_create_short_url(
    long_url: str,
    custom_slug: str | None = None,
    tags: list[str] | None = None,
    domain: str | None = None,
    title: str | None = None,
    valid_since: str | None = None,
    valid_until: str | None = None,
    max_visits: int | None = None,
    crawlable: bool | None = None,
    confirm: bool = False,
) -> dict:
    """Crée un lien court.

    valid_since / valid_until : ISO-8601 (ex. 2026-12-31T23:59:59+00:00).
    Écriture réelle seulement si confirm=True et SHLINK_ALLOW_WRITES=1.
    """
    body = {"longUrl": long_url}
    optional = {
        "customSlug": custom_slug,
        "tags": tags,
        "domain": domain,
        "title": title,
        "validSince": valid_since,
        "validUntil": valid_until,
        "maxVisits": max_visits,
        "crawlable": crawlable,
    }
    for k, v in optional.items():
        if v is not None:
            body[k] = v
    preview = _write_guard("create", body) if not confirm else None
    if preview:
        return preview
    return _call("POST", "/short-urls", body=body)


@mcp.tool()
def shlink_update_short_url(
    short_code: str,
    long_url: str | None = None,
    custom_slug: str | None = None,
    tags: list[str] | None = None,
    title: str | None = None,
    valid_since: str | None = None,
    valid_until: str | None = None,
    max_visits: int | None = None,
    confirm: bool = False,
) -> dict:
    """Modifie un lien court (PATCH). Exige confirm=True."""
    body = {}
    optional = {
        "longUrl": long_url,
        "customSlug": custom_slug,
        "tags": tags,
        "title": title,
        "validSince": valid_since,
        "validUntil": valid_until,
        "maxVisits": max_visits,
    }
    for k, v in optional.items():
        if v is not None:
            body[k] = v
    preview = _write_guard("update", body) if not confirm else None
    if preview:
        return preview
    return _call("PATCH", "/short-urls/" + short_code, body=body)


@mcp.tool()
def shlink_delete_short_url(
    short_code: str, domain: str | None = None, confirm: bool = False
) -> dict:
    """Supprime un lien court. Exige confirm=True."""
    preview = _write_guard("delete", {"shortCode": short_code}) \
        if not confirm else None
    if preview:
        return preview
    return _call("DELETE", "/short-urls/" + short_code, {"domain": domain})


@mcp.tool()
def shlink_visits(
    short_code: str | None = None,
    tag: str | None = None,
    domain: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    exclude_bots: bool = True,
    page: int = 1,
    items_per_page: int = 20,
) -> dict:
    """Visites : d'un lien si short_code, sinon globales (ou par tag/domaine)."""
    query = {
        "startDate": start_date,
        "endDate": end_date,
        "excludeBots": str(exclude_bots).lower(),
        "page": page,
        "itemsPerPage": items_per_page,
    }
    if short_code:
        query["domain"] = domain
        return _call("GET", "/short-urls/" + short_code + "/visits", query)
    if tag:
        return _call("GET", "/tags/" + tag + "/visits", query)
    if domain:
        query["domain"] = domain
        return _call("GET", "/domains/" + domain + "/visits", query)
    return _call("GET", "/visits", query)


@mcp.tool()
def shlink_tags(with_stats: bool = True) -> dict:
    """Tags de l'instance, avec le nombre de liens et de visites."""
    return _call("GET", "/tags/stats" if with_stats else "/tags", {
        "withStats": str(with_stats).lower(),
    })


@mcp.tool()
def shlink_domains() -> dict:
    """Domaines servis par cette instance (multi-domaine + redirects)."""
    return _call("GET", "/domains")


@mcp.tool()
def shlink_request(
    method: str,
    path: str,
    query: dict | None = None,
    body: dict | None = None,
    confirm: bool = False,
) -> dict:
    """Échappatoire complète sur l'API REST v3.

    method: GET/POST/PATCH/PUT/DELETE ; path relatif à /rest/v3, ex.
    "/redirect-rules/abc" ou "/visits/orphan". Couvre tout ce que Shlink
    expose (redirect rules, visites orphelines, custom slugs, etc.).
    Toute méthode autre que GET exige confirm=True.
    """
    method = method.upper()
    if method not in ("GET", "POST", "PATCH", "PUT", "DELETE"):
        return {"error": "méthode non supportée: %s" % method}
    if not path.startswith("/"):
        path = "/" + path
    if method != "GET" and not confirm:
        return _write_guard(method, {"path": path, "query": query,
                                     "body": body}) or {}
    return _call(method, path, query, body)


if __name__ == "__main__":
    mcp.run()
