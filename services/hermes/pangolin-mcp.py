"""Pangolin MCP server: self-hosted Integration API v1.

Curated tools (sites, resources, targets, users, roles,
blueprints...) + one auto-generated tool per endpoint from
the instance's /openapi.json + api_request as an escape hatch.
The key (root API key) is re-read on every call from the
sops file.
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
            "API key missing: "
            + KEY_FILE
            + " unreadable and PANGOLIN_API_KEY empty"
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
            "HTTP %s on %s %s: %s"
            % (e.code, method, path, detail[:600])
        )
    except OSError as e:
        raise RuntimeError(
            "%s %s unreachable: %s" % (method, path, e)
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
            "PANGOLIN_READ_ONLY=1: write refused"
        )


@mcp.tool()
def status() -> dict:
    """Tests the connection to the Pangolin API (key + base URL).

    Returns base_url, read_only and the number of visible
    organizations; on failure the raw HTTP error is raised here.
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
    """Lists the organizations (orgId, name, usage counters)."""
    return _call("GET", "/orgs")


@mcp.tool()
def get_org(org_id: str) -> dict:
    """Details of an organization by its orgId."""
    return _call("GET", "/org/" + org_id)


@mcp.tool()
def list_sites(org_id: str) -> dict:
    """Lists the organization's sites (siteId, niceId, type)."""
    return _call("GET", "/org/" + org_id + "/sites")


@mcp.tool()
def get_site(org_id: str, nice_id: str) -> dict:
    """Details of a site by orgId + niceId (readable id)."""
    return _call(
        "GET", "/org/" + org_id + "/site/" + nice_id
    )


@mcp.tool()
def create_site(
    org_id: str, name: str, subnet: str = "", exit_node_id: int = 0
) -> dict:
    """Creates a newt-type site (tunnel) in the organization.

    Returns newtId + secret to reuse in the machine's newt
    config. subnet/exit_node_id: defaults via
    pick_site_defaults. Side effect (delete_site to cancel).
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
    """Defaults for creating a site (exit node, subnet, newtId...).

    Read before create_site to reuse subnet/exitNodeId.
    """
    return _call("GET", "/org/" + org_id + "/pick-site-defaults")


@mcp.tool()
def approve_site(site_id: int) -> dict:
    """Approves a pending site (and activates its resources)."""
    _write()
    return _call(
        "POST", "/site/%d/approve" % site_id, {}
    )


@mcp.tool()
def delete_site(site_id: int) -> dict:
    """Deletes a site and all its associated data.

    Irreversible.
    """
    _write()
    return _call("DELETE", "/site/%d" % site_id)


@mcp.tool()
def list_domains(org_id: str) -> dict:
    """Lists the organization's domains (domainId, base)."""
    return _call("GET", "/org/" + org_id + "/domains")


@mcp.tool()
def list_resources(org_id: str) -> dict:
    """Lists the organization's public resources."""
    return _call(
        "GET", "/org/" + org_id + "/public-resources"
    )


@mcp.tool()
def get_resource(resource_id: int) -> dict:
    """Details of a public resource (with targets and policy)."""
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
    """Creates a public resource in the organization.

    mode: http (default), ssh, rdp, vnc, tcp, udp, inference.
    subdomain/domain_id optional (auto otherwise). Then add
    the target with add_target. Side effect.
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
    """Updates a public resource (partial POST).

    fields: dict of modified fields, e.g. {"name": "x"} or
    {"subdomain": "y", "domainId": "1"}. Side effect.
    """
    _write()
    return _call(
        "POST", "/public-resource/%d" % resource_id, fields
    )


@mcp.tool()
def delete_resource(resource_id: int) -> dict:
    """Deletes a public resource and its targets.

    Irreversible.
    """
    _write()
    return _call(
        "DELETE", "/public-resource/%d" % resource_id
    )


@mcp.tool()
def list_targets(resource_id: int) -> dict:
    """Lists the targets of a public resource."""
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
    """Adds a target to a public resource.

    site_id: site that reaches the target. ip/port: destination
    seen from that site (e.g. "127.0.0.1", 8070). method: http, ssh,
    rdp, vnc. Side effect.
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
    """Updates a target by targetId.

    fields: dict of modified fields (ip, port, enabled...).
    Side effect.
    """
    _write()
    return _call(
        "POST", "/target/%d" % target_id, fields
    )


@mcp.tool()
def delete_target(target_id: int) -> dict:
    """Deletes a target. Irreversible."""
    _write()
    return _call("DELETE", "/target/%d" % target_id)


@mcp.tool()
def list_private_resources(org_id: str) -> dict:
    """Lists the organization's private resources (site resources)."""
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
    """Creates a private resource (site resource) in the org.

    mode: host, cidr, http or ssh. destination/destination_port:
    host and port reached by the site; alias: optional internal
    FQDN; domain_id/scheme: required for http mode
    (e.g. domain1 + http); subdomain: subdomain to reserve
    in domain_id (e.g. cloud -> cloud.marcpartensky.com), exclusive
    with alias; tcp_range/udp_range: ranges "1000-2000";
    user_ids/role_ids/client_ids: access (empty by default).
    Side effect.
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
    """Details of a private resource by siteResourceId."""
    return _call(
        "GET",
        "/private-resource/%d" % site_resource_id,
        query={"orgId": org_id},
    )


@mcp.tool()
def delete_private_resource(site_resource_id: int) -> dict:
    """Deletes a private resource. Irreversible."""
    _write()
    return _call(
        "DELETE", "/private-resource/%d" % site_resource_id
    )


@mcp.tool()
def update_private_resource(site_resource_id: int, fields: dict) -> dict:
    """Updates a private resource (partial POST).

    fields: fields to modify (e.g. {"subdomain": "cloud.p2p"} or
    {"enabled": false}); omitted fields stay unchanged. For
    http modes, domainId + subdomain go together. Side effect.
    """
    _write()
    return _call(
        "POST", "/private-resource/%d" % site_resource_id, fields
    )


@mcp.tool()
def list_roles(org_id: str) -> dict:
    """Lists the organization's roles (roleId, name)."""
    return _call("GET", "/org/" + org_id + "/roles")


@mcp.tool()
def list_users(org_id: str) -> dict:
    """Lists the organization's users."""
    return _call("GET", "/org/" + org_id + "/users")


@mcp.tool()
def create_user(
    org_id: str,
    username: str,
    email: str = "",
    name: str = "",
    role_ids: list | None = None,
) -> dict:
    """Creates an internal user in the organization.

    With no password and no invitation sent, it cannot log
    in. Side effect, check username/email first.
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
    """Lists the blueprints applied to the organization."""
    return _call("GET", "/org/" + org_id + "/blueprints")


@mcp.tool()
def apply_blueprint(org_id: str, blueprint_json: str) -> dict:
    """Applies a JSON blueprint to the organization.

    blueprint_json: raw JSON as text (not YAML nor
    base64, base64 encoding is done here). Can create/modify
    sites, resources and targets. Major side effect.
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
    """Lists the org's API keys (never the value, only the id)."""
    return _call("GET", "/org/" + org_id + "/api-keys")


@mcp.tool()
def api_request(
    method: str,
    path: str,
    body: dict | None = None,
    query: dict | None = None,
) -> dict | list | str:
    """Calls an arbitrary v1 endpoint (full coverage).

    method: GET, POST, PUT, PATCH or DELETE. path: path
    after /v1, e.g. "/org/{orgId}/sites". body/query: optional
    JSON dicts. See list_api_endpoints to find the
    appropriate route.
    """
    m = method.upper()
    if m not in METHODS:
        raise RuntimeError("unsupported method: " + method)
    if not path.startswith("/"):
        path = "/" + path
    if m != "GET":
        _write()
    return _call(m, path, body, query)


@mcp.tool()
def list_api_endpoints(search: str = "") -> list:
    """Lists the instance spec's endpoints (filtered).

    Returns "METHOD /path | summary" of the operations containing
    `search` (default: everything, capped at 300). Used to prepare an
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
    else:  # pragma: no cover - old FastMCP
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
                "Auto-generated from /openapi.json (instance "
                "spec); body/query = optional JSON dicts."
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
