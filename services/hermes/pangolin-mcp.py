"""Serveur MCP Pangolin : Integration API v1 self-hosted.

Tools curatés (sites, ressources, targets, users, roles,
blueprints...) + un tool auto-généré par endpoint depuis
/openapi.json de l'instance + api_request en échappatoire.
La clé (root API key) est relue à chaque appel depuis le
fichier sops.
"""

import base64
import inspect
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

DEFAULT_URL = "https://api.marcpartensky.com/v1"
BASE_URL = os.environ.get("PANGOLIN_BASE_URL", DEFAULT_URL)
KEY_FILE = os.environ.get(
    "PANGOLIN_API_KEY_FILE", "/run/secrets/pangolin_api_key"
)
READ_ONLY = os.environ.get("PANGOLIN_READ_ONLY", "0") == "1"
METHODS = ("GET", "POST", "PUT", "DELETE", "PATCH")

mcp = MCPServer("pangolin")


def _api_key():
    key = ""
    try:
        with open(KEY_FILE) as f:
            key = f.read().strip()
    except OSError:
        pass
    key = key or os.environ.get("PANGOLIN_API_KEY", "")
    if not key:
        raise RuntimeError(
            "Clé API absente : "
            + KEY_FILE
            + " illisible et PANGOLIN_API_KEY vide"
        )
    return key


def _request(method, path, body=None, query=None, auth=True,
             timeout=60):
    url = BASE_URL.rstrip("/") + path
    if query:
        query = {k: v for k, v in query.items() if v is not None}
        url += "?" + urllib.parse.urlencode(query)
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if auth:
        headers["Authorization"] = "Bearer " + _api_key()
    req = urllib.request.Request(
        url, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise RuntimeError(
            "HTTP %s sur %s %s : %s"
            % (e.code, method, path, detail[:600])
        )
    except OSError as e:
        raise RuntimeError(
            "%s %s injoignable : %s" % (method, path, e)
        )
    if not raw:
        return {"ok": True}
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode(errors="replace")


def _call(method, path, body=None, query=None, timeout=60):
    resp = _request(
        method, path, body=body, query=query, timeout=timeout
    )
    if isinstance(resp, dict) and resp.get("success") is False:
        detail = resp.get("message") or str(resp)[:300]
        raise RuntimeError(
            "API %s %s : %s" % (method, path, detail)
        )
    if isinstance(resp, dict):
        data = resp.get("data")
        return data if data is not None else {"ok": True}
    return resp


def _write():
    if READ_ONLY:
        raise RuntimeError(
            "PANGOLIN_READ_ONLY=1 : écriture refusée"
        )


@mcp.tool()
def status() -> dict:
    """Teste la connexion à l'API Pangolin (clé + URL de base).

    Renvoie base_url, read_only et le nombre d'organisations
    visibles ; en cas d'échec l'erreur HTTP brute remonte ici.
    """
    out = {"base_url": BASE_URL, "read_only": READ_ONLY}
    try:
        resp = _request("GET", "/orgs")
    except RuntimeError as e:
        out["ok"] = False
        out["error"] = str(e)
        return out
    data = resp.get("data") if isinstance(resp, dict) else {}
    out["ok"] = True
    out["orgs"] = len((data or {}).get("orgs") or [])
    return out


@mcp.tool()
def list_orgs() -> dict:
    """Liste les organisations (orgId, nom, compteurs d'usage)."""
    return _call("GET", "/orgs")


@mcp.tool()
def get_org(org_id: str) -> dict:
    """Détail d'une organisation par son orgId."""
    return _call("GET", "/org/" + org_id)


@mcp.tool()
def list_sites(org_id: str) -> dict:
    """Liste les sites de l'organisation (siteId, niceId, type)."""
    return _call("GET", "/org/" + org_id + "/sites")


@mcp.tool()
def get_site(org_id: str, nice_id: str) -> dict:
    """Détail d'un site par orgId + niceId (id lisible)."""
    return _call(
        "GET", "/org/" + org_id + "/site/" + nice_id
    )


@mcp.tool()
def create_site(
    org_id: str, name: str, subnet: str = "", exit_node_id: int = 0
) -> dict:
    """Crée un site de type newt (tunnel) dans l'organisation.

    Renvoie newtId + secret à réutiliser dans la config newt de
    la machine. subnet/exit_node_id : défauts via
    pick_site_defaults. Effet de bord (delete_site pour annuler).
    """
    _write()
    body = {"name": name, "type": "newt"}
    if subnet:
        body["subnet"] = subnet
    if exit_node_id:
        body["exitNodeId"] = exit_node_id
    return _call("PUT", "/org/" + org_id + "/site", body)


@mcp.tool()
def pick_site_defaults(org_id: str) -> dict:
    """Défauts pour créer un site (exit node, subnet, newtId...).

    À lire avant create_site pour reprendre subnet/exitNodeId.
    """
    return _call("GET", "/org/" + org_id + "/pick-site-defaults")


@mcp.tool()
def approve_site(site_id: int) -> dict:
    """Approuve un site en attente (et active ses ressources)."""
    _write()
    return _call(
        "POST", "/site/%d/approve" % site_id, {}
    )


@mcp.tool()
def delete_site(site_id: int) -> dict:
    """Supprime un site et toutes ses données associées.

    Irréversible.
    """
    _write()
    return _call("DELETE", "/site/%d" % site_id)


@mcp.tool()
def list_domains(org_id: str) -> dict:
    """Liste les domaines de l'organisation (domainId, base)."""
    return _call("GET", "/org/" + org_id + "/domains")


@mcp.tool()
def list_resources(org_id: str) -> dict:
    """Liste les ressources publiques de l'organisation."""
    return _call(
        "GET", "/org/" + org_id + "/public-resources"
    )


@mcp.tool()
def get_resource(resource_id: int) -> dict:
    """Détail d'une ressource publique (avec targets et policy)."""
    return _call(
        "GET", "/public-resource/%d" % resource_id
    )


@mcp.tool()
def create_resource(
    org_id: str,
    name: str,
    mode: str = "http",
    subdomain: str = "",
    domain_id: str = "",
) -> dict:
    """Crée une ressource publique dans l'organisation.

    mode : http (défaut), ssh, rdp, vnc, tcp, udp, inference.
    subdomain/domain_id optionnels (auto sinon). Ajouter ensuite
    la cible avec add_target. Effet de bord.
    """
    _write()
    body = {"name": name, "mode": mode}
    if subdomain:
        body["subdomain"] = subdomain
    if domain_id:
        body["domainId"] = domain_id
    return _call(
        "PUT", "/org/" + org_id + "/public-resource", body
    )


@mcp.tool()
def update_resource(resource_id: int, fields: dict) -> dict:
    """Met à jour une ressource publique (POST partiel).

    fields : dict des champs modifiés, ex. {"name": "x"} ou
    {"subdomain": "y", "domainId": "1"}. Effet de bord.
    """
    _write()
    return _call(
        "POST", "/public-resource/%d" % resource_id, fields
    )


@mcp.tool()
def delete_resource(resource_id: int) -> dict:
    """Supprime une ressource publique et ses targets.

    Irréversible.
    """
    _write()
    return _call(
        "DELETE", "/public-resource/%d" % resource_id
    )


@mcp.tool()
def list_targets(resource_id: int) -> dict:
    """Liste les cibles (targets) d'une ressource publique."""
    return _call(
        "GET", "/public-resource/%d/targets" % resource_id
    )


@mcp.tool()
def add_target(
    resource_id: int,
    site_id: int,
    ip: str,
    port: int,
    method: str = "http",
) -> dict:
    """Ajoute une cible (target) à une ressource publique.

    site_id : site qui joint la cible. ip/port : destination vue
    depuis ce site (ex. "127.0.0.1", 8070). method : http, ssh,
    rdp, vnc. Effet de bord.
    """
    _write()
    body = {
        "siteId": site_id,
        "ip": ip,
        "port": port,
        "method": method,
    }
    return _call(
        "PUT", "/public-resource/%d/target" % resource_id, body
    )


@mcp.tool()
def update_target(target_id: int, fields: dict) -> dict:
    """Met à jour une cible (target) par targetId.

    fields : dict des champs modifiés (ip, port, enabled...).
    Effet de bord.
    """
    _write()
    return _call(
        "POST", "/target/%d" % target_id, fields
    )


@mcp.tool()
def delete_target(target_id: int) -> dict:
    """Supprime une cible (target). Irréversible."""
    _write()
    return _call("DELETE", "/target/%d" % target_id)


@mcp.tool()
def list_private_resources(org_id: str) -> dict:
    """Liste les ressources privées (site resources) de l'org."""
    return _call(
        "GET", "/org/" + org_id + "/private-resources"
    )


@mcp.tool()
def create_private_resource(
    org_id: str,
    name: str,
    mode: str,
    site_id: int,
    destination: str,
    destination_port: int = 0,
    alias: str = "",
    domain_id: str = "",
    subdomain: str = "",
    scheme: str = "",
    tcp_range: str = "",
    udp_range: str = "",
    user_ids: list | None = None,
    role_ids: list | None = None,
    client_ids: list | None = None,
) -> dict:
    """Crée une ressource privée (site resource) dans l'org.

    mode : host, cidr, http ou ssh. destination/destination_port :
    hôte et port joints par le site ; alias : FQDN interne
    optionnel ; domain_id/scheme : requis pour le mode http
    (ex. domain1 + http) ; subdomain : sous-domaine à réserver
    dans domain_id (ex. cloud → cloud.marcpartensky.com), exclusif
    avec alias ; tcp_range/udp_range : plages "1000-2000" ;
    user_ids/role_ids/client_ids : accès (vides par défaut).
    Effet de bord.
    """
    _write()
    body = {
        "name": name,
        "mode": mode,
        "siteId": site_id,
        "userIds": user_ids or [],
        "roleIds": role_ids or [],
        "clientIds": client_ids or [],
    }
    if destination:
        body["destination"] = destination
    if destination_port:
        body["destinationPort"] = destination_port
    if alias:
        body["alias"] = alias
    if domain_id:
        body["domainId"] = domain_id
    if subdomain:
        body["subdomain"] = subdomain
    if scheme:
        body["scheme"] = scheme
    if tcp_range:
        body["tcpPortRangeString"] = tcp_range
    if udp_range:
        body["udpPortRangeString"] = udp_range
    return _call(
        "PUT", "/org/" + org_id + "/private-resource", body
    )


@mcp.tool()
def get_private_resource(org_id: str, site_resource_id: int) -> dict:
    """Détail d'une ressource privée par siteResourceId."""
    return _call(
        "GET",
        "/private-resource/%d" % site_resource_id,
        query={"orgId": org_id},
    )


@mcp.tool()
def delete_private_resource(site_resource_id: int) -> dict:
    """Supprime une ressource privée. Irréversible."""
    _write()
    return _call(
        "DELETE", "/private-resource/%d" % site_resource_id
    )


@mcp.tool()
def update_private_resource(site_resource_id: int, fields: dict) -> dict:
    """Met à jour une ressource privée (POST partiel).

    fields : champs à modifier (ex. {"subdomain": "cloud.p2p"} ou
    {"enabled": false}) ; les champs omis restent inchangés. Pour
    les modes http, domainId + subdomain vont ensemble. Effet de bord.
    """
    _write()
    return _call(
        "POST", "/private-resource/%d" % site_resource_id, fields
    )


@mcp.tool()
def list_roles(org_id: str) -> dict:
    """Liste les rôles de l'organisation (roleId, nom)."""
    return _call("GET", "/org/" + org_id + "/roles")


@mcp.tool()
def list_users(org_id: str) -> dict:
    """Liste les utilisateurs de l'organisation."""
    return _call("GET", "/org/" + org_id + "/users")


@mcp.tool()
def create_user(
    org_id: str,
    username: str,
    email: str = "",
    name: str = "",
    role_ids: list | None = None,
) -> dict:
    """Crée un utilisateur interne dans l'organisation.

    Sans mot de passe ni invitation envoyée, il ne peut pas se
    connecter. Effet de bord, vérifier username/email avant.
    """
    _write()
    body = {"username": username}
    if email:
        body["email"] = email
    if name:
        body["name"] = name
    if role_ids:
        body["roleIds"] = role_ids
    return _call("PUT", "/org/" + org_id + "/user", body)


@mcp.tool()
def list_blueprints(org_id: str) -> dict:
    """Liste les blueprints appliqués à l'organisation."""
    return _call("GET", "/org/" + org_id + "/blueprints")


@mcp.tool()
def apply_blueprint(org_id: str, blueprint_json: str) -> dict:
    """Applique un blueprint JSON à l'organisation.

    blueprint_json : JSON brut en texte (pas du YAML ni du
    base64, l'encodage base64 est fait ici). Peut créer/modifier
    sites, ressources et cibles. Effet de bord important.
    """
    _write()
    b64 = base64.b64encode(
        blueprint_json.encode()
    ).decode()
    return _call(
        "PUT", "/org/" + org_id + "/blueprint",
        {"blueprint": b64},
    )


@mcp.tool()
def list_api_keys(org_id: str) -> dict:
    """Liste les clés API de l'org (jamais la valeur, l'id seul)."""
    return _call("GET", "/org/" + org_id + "/api-keys")


@mcp.tool()
def api_request(
    method: str,
    path: str,
    body: dict | None = None,
    query: dict | None = None,
) -> dict | list | str:
    """Appelle un endpoint v1 arbitraire (couverture complète).

    method : GET, POST, PUT, PATCH ou DELETE. path : chemin
    après /v1, ex. "/org/{orgId}/sites". body/query : dicts
    JSON optionnels. Voir list_api_endpoints pour trouver la
    route adéquate.
    """
    m = method.upper()
    if m not in METHODS:
        raise RuntimeError("méthode non supportée : " + method)
    if not path.startswith("/"):
        path = "/" + path
    if m != "GET":
        _write()
    return _call(m, path, body, query)


@mcp.tool()
def list_api_endpoints(search: str = "") -> list:
    """Liste les endpoints de la spec de l'instance (filtré).

    Renvoie "METHOD /chemin | résumé" des opérations contenant
    `search` (défaut : tout, plafonné à 300). Sert à préparer un
    api_request.
    """
    spec = _request(
        "GET", "/openapi.json", auth=False, timeout=20
    )
    out = []
    for p, ops in (spec.get("paths") or {}).items():
        for m, op in ops.items():
            if m.upper() not in METHODS:
                continue
            line = "%s %s | %s" % (
                m.upper(), p, (op.get("summary") or "")
            )
            if not search or search.lower() in line.lower():
                out.append(line)
    return out[:300]


def _path_params(path_tpl):
    return [n for n in re.findall(r"\{([^{}]+)\}", path_tpl) if n]


def _endpoint_fn(method, path_tpl, param_names):
    def fn(**kwargs):
        args = {k: kwargs.pop(k) for k in param_names}
        body = kwargs.pop("body", None)
        query = kwargs.pop("query", None)
        if method != "GET":
            _write()
        path = path_tpl
        for k, v in args.items():
            path = path.replace(
                "{" + k + "}",
                urllib.parse.quote(str(v), safe=""),
            )
        return _call(method, path, body, query)

    sig = [
        inspect.Parameter(
            k,
            inspect.Parameter.KEYWORD_ONLY,
            annotation=str | int,
        )
        for k in param_names
    ]
    sig.append(
        inspect.Parameter(
            "body",
            inspect.Parameter.KEYWORD_ONLY,
            annotation=dict | None,
            default=None,
        )
    )
    sig.append(
        inspect.Parameter(
            "query",
            inspect.Parameter.KEYWORD_ONLY,
            annotation=dict | None,
            default=None,
        )
    )
    fn.__signature__ = inspect.Signature(sig)
    return fn


def _register(fn, name, doc):
    if hasattr(mcp, "add_tool"):
        mcp.add_tool(fn, name=name, description=doc)
    else:  # pragma: no cover - vieux FastMCP
        fn.__name__ = name
        fn.__doc__ = doc
        mcp.tool()(fn)


def _register_endpoint_tools():
    try:
        spec = _request(
            "GET", "/openapi.json", auth=False, timeout=10
        )
    except RuntimeError:
        return 0
    if not isinstance(spec, dict):
        return 0
    seen = set()
    count = 0
    for path_tpl, ops in (spec.get("paths") or {}).items():
        if path_tpl in ("/", "/openapi.json", "/openapi.yaml"):
            continue
        for method, op in ops.items():
            m = method.upper()
            if m not in METHODS:
                continue
            raw = op.get("operationId") or (m + " " + path_tpl)
            name = re.sub(r"[^0-9a-zA-Z_]+", "_", raw).strip("_")
            name = name or "endpoint"
            base, i = name, 2
            while name in seen:
                name = "%s_%d" % (base, i)
                i += 1
            seen.add(name)
            bits = [m + " " + path_tpl]
            summ = (op.get("summary") or "").strip()
            if summ:
                bits.append(summ)
            tags = ", ".join(op.get("tags") or [])
            if tags:
                bits.append("tags: " + tags)
            bits.append(
                "Auto-généré depuis /openapi.json (spec de "
                "l'instance) ; body/query = dicts JSON optionnels."
            )
            fn = _endpoint_fn(
                m, path_tpl, _path_params(path_tpl)
            )
            _register(fn, name, "\n".join(bits))
            count += 1
    return count


if __name__ == "__main__":
    _register_endpoint_tools()
    mcp.run()
