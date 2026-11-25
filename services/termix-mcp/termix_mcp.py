"""MCP server Termix: drives tower's server panel through its HTTP API.

Termix has no upstream MCP and its API mostly covers the panel's
inventory (hosts, plugins, audit, accounts). Two capabilities interest the agent:

- the inventory and state of the hosts, without ever reading the stored
  credentials (`/host/db/host/:id/password` is NOT exposed here);
- command execution, via the Snippets plugin: Termix itself opens
  the SSH session and returns stdout/stderr/exit code. No SSH key
  travels in the call, but this assumes Termix already holds a
  usable credential for the target host.

Auth: Termix API key (`tmx_...`) re-read on each call from
TERMIX_API_KEY_FILE (sops secret) or TERMIX_API_KEY.

Write policy: mutating tools require `confirm=True`, otherwise they
return the call preview without sending anything. Reads require nothing.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request
import uuid

from mcp.server.fastmcp import FastMCP

BASE_URL = os.environ.get(
    "TERMIX_URL", "http://127.0.0.1:9160").rstrip("/")
KEY_FILE = os.environ.get("TERMIX_API_KEY_FILE", "")
TIMEOUT = float(os.environ.get("TERMIX_TIMEOUT", "30"))

mcp = FastMCP("termix")


def _api_key():
    key = ""
    if KEY_FILE:
        try:
            with open(KEY_FILE, "r", encoding="utf-8") as fh:
                key = fh.read().strip()
        except OSError:
            key = ""
    key = key or os.environ.get("TERMIX_API_KEY", "")
    if not key:
        raise RuntimeError(
            "Termix API key missing: " + (KEY_FILE or "TERMIX_API_KEY_FILE")
            + " unreadable and TERMIX_API_KEY empty")
    return key


def _call(method, path, body=None, query=None, timeout=None):
    """Raw HTTP call. Raises a RuntimeError with the error body."""
    url = BASE_URL + path
    if query:
        clean = {k: v for k, v in query.items() if v is not None}
        if clean:
            url += "?" + urllib.parse.urlencode(clean)
    data = None
    headers = {
        "Accept": "application/json",
        "Authorization": "Bearer " + _api_key(),
    }
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(
                req, timeout=timeout or TIMEOUT) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(
            "HTTP %s on %s %s : %s"
            % (exc.code, method, path, detail[:600]))
    except OSError as exc:
        raise RuntimeError(
            "%s %s unreachable : %s" % (method, url, exc))
    if not raw:
        return None
    return json.loads(raw.decode(errors="replace"))


def _preview(method, path, body):
    return ("DRY RUN, nothing was sent : %s %s\n%s"
            % (method, path, json.dumps(body, indent=1, ensure_ascii=False)))


def _host_summary(host):
    """Short view of a host: never a secret or a key blob."""
    return {
        "id": host.get("id"),
        "name": host.get("name"),
        "ip": host.get("ip"),
        "port": host.get("port"),
        "username": host.get("username"),
        "folder": host.get("folder"),
        "tags": host.get("tags") or [],
        "authType": host.get("authType"),
        "credentialId": host.get("credentialId"),
        "hasStoredPassword": bool(host.get("password")),
        "statusCheckEnabled": host.get("statusCheckEnabled"),
    }


@mcp.tool()
def status() -> str:
    """Smoke test: auth, version, number of hosts and plugins.

    Call this first when another tool fails: a 401 here means
    that the API key is missing, revoked or pointed at the wrong host.
    """
    try:
        me = _call("GET", "/users/me")
    except RuntimeError as exc:
        return "auth FAILED : " + str(exc)
    out = {"url": BASE_URL, "me": me}
    for label, path in (("version", "/version"), ("hosts", "/host/db/host"),
                        ("plugins", "/plugins")):
        try:
            value = _call("GET", path)
        except RuntimeError as exc:
            out[label] = "error : " + str(exc)[:200]
            continue
        if isinstance(value, list):
            out[label] = "%d elements" % len(value)
        else:
            out[label] = value
    return json.dumps(out, indent=1, ensure_ascii=False)


@mcp.tool()
def list_hosts(search: str = "", tag: str = "") -> str:
    """Lists Termix hosts (id, name, ip, user, tags, auth type).

    `search` filters on the name, the IP and the user (case-insensitive);
    `tag` filters on an exact tag. Never returns a password or a key.
    """
    hosts = _call("GET", "/host/db/host") or []
    needle = search.strip().lower()
    rows = []
    for host in hosts:
        if tag and tag not in (host.get("tags") or []):
            continue
        if needle:
            blob = " ".join(str(host.get(k, "")) for k in
                            ("name", "ip", "username", "folder")).lower()
            if needle not in blob:
                continue
        rows.append(_host_summary(host))
    return json.dumps(rows, indent=1, ensure_ascii=False)


@mcp.tool()
def get_host(host_id: int) -> str:
    """Details of a host: SSH config, options, per-plugin defaults.

    The stored password is removed from the response; use the Termix UI
    to view it, not the agent.
    """
    host = _call("GET", "/host/db/host/%d" % host_id)
    if isinstance(host, dict):
        host.pop("password", None)
    return json.dumps(host, indent=1, ensure_ascii=False)


@mcp.tool()
def update_host(host_id: int, fields: str = "{}",
                confirm: bool = False) -> str:
    """Modifies an existing host (partial PUT).

    `fields` is a JSON object of the fields to change, for example
    {"name": "deck", "tags": ["deck"], "port": 22}. Without `confirm=True`,
    only returns the call preview.
    """
    try:
        payload = json.loads(fields or "{}")
    except ValueError as exc:
        return "fields is not valid JSON : %s" % exc
    if not isinstance(payload, dict) or not payload:
        return "fields must be a non-empty JSON object."
    path = "/host/db/host/%d" % host_id
    if not confirm:
        return _preview("PUT", path, payload)
    result = _call("PUT", path, payload)
    return json.dumps(result, indent=1, ensure_ascii=False)


@mcp.tool()
def delete_host(host_id: int, confirm: bool = False) -> str:
    """Deletes a host from the Termix inventory. IRREVERSIBLE.

    Does not touch the remote machine, only the Termix entry. Requires
    `confirm=True`.
    """
    path = "/host/db/host/%d" % host_id
    if not confirm:
        return _preview("DELETE", path, {"host_id": host_id})
    return json.dumps(_call("DELETE", path),
                      indent=1, ensure_ascii=False)


@mcp.tool()
def host_status(host_id: int = 0, refresh: bool = False) -> str:
    """Online/offline state of the hosts (TCP probe of the Host Status plugin).

    `host_id=0` returns all hosts. `refresh=True` forces a new probe
    instead of the last known result.
    """
    if refresh:
        _call("POST", "/host/status/refresh")
    if host_id:
        return json.dumps(_call("GET", "/host/status/%d" % host_id),
                          indent=1, ensure_ascii=False)
    return json.dumps(_call("GET", "/host/status"),
                      indent=1, ensure_ascii=False)


@mcp.tool()
def exec(host_id: int, command: str, timeout_s: int = 60) -> str:
    """Runs a command on a host, via the Termix Snippets plugin.

    Termix itself opens the SSH session and returns stdout, stderr and the exit
    code. Creates a temporary snippet, runs it, deletes it.

    Assumes Termix holds a usable credential for this host: a
    host in authType=key without credentialId replies SSH_AUTH_FAILED. On
    code 255, the command did not run at all.
    """
    name = "__hermes_exec_" + uuid.uuid4().hex[:8]
    created = _call("POST", "/plugin-api/snippets/",
                    {"name": name, "content": command})
    snippet_id = (created or {}).get("id")
    if not snippet_id:
        return "Cannot create the snippet : " + json.dumps(
            created, ensure_ascii=False)[:300]
    try:
        result = _call(
            "POST", "/plugin-api/snippets/execute",
            {"snippetId": snippet_id, "hostId": host_id},
            timeout=max(timeout_s, 15) + 30)
    except RuntimeError as exc:
        raise RuntimeError("Execution on host %s : %s"
                           % (host_id, exc))
    finally:
        try:
            _call("DELETE", "/plugin-api/snippets/%s" % snippet_id)
        except RuntimeError:
            pass
    return json.dumps(result, indent=1, ensure_ascii=False)


@mcp.tool()
def plugins(enabled_only: bool = False) -> str:
    """Lists the installed Termix plugins: id, name, version, state.

    Useful to know which capability is served (e.g. snippets, docker,
    service-manager) and whether a plugin is disabled (503 on its routes).
    """
    rows = _call("GET", "/plugins") or []
    out = []
    for plug in rows:
        if enabled_only and not plug.get("enabled"):
            continue
        out.append({
            "id": plug.get("id"),
            "name": plug.get("name"),
            "version": plug.get("version"),
            "enabled": plug.get("enabled"),
            "state": plug.get("state"),
        })
    return json.dumps(out, indent=1, ensure_ascii=False)


@mcp.tool()
def audit(limit: int = 25, action: str = "") -> str:
    """Latest entries of the Termix audit log.

    `action` filters on an operation name (e.g. user_login). Shows who did
    what in the panel, not what happens on the machines.
    """
    entries = _call("GET", "/audit-logs",
                    query={"limit": limit, "action": action or None})
    if isinstance(entries, dict):
        entries = entries.get("logs") or entries.get("entries") or entries
    if isinstance(entries, list):
        entries = entries[:limit]
    return json.dumps(entries, indent=1, ensure_ascii=False)


@mcp.tool()
def api(method: str, path: str, body: str = "",
        confirm: bool = False) -> str:
    """Escape hatch: any Termix route, in JSON.

    `path` starts with a prefix proxied by the instance: /host, /users,
    /rbac, /plugins, /credentials, /database, /audit-logs, /operations,
    /open-tabs, /plugin-api/<plugin>/... A path outside these prefixes returns
    the SPA in 200 with HTML, not an error.

    Methods other than GET require `confirm=True`. Do not use it
    to read the stored credentials: `get_host` removes them on purpose
    and `/host/db/host/<id>/password` stays outside the agent's scope.
    """
    verb = method.strip().upper()
    if not path.startswith("/"):
        return "path must start with /"
    payload = None
    if body.strip():
        try:
            payload = json.loads(body)
        except ValueError as exc:
            return "body is not valid JSON : %s" % exc
    if verb != "GET" and not confirm:
        return _preview(verb, path, payload)
    result = _call(verb, path, payload)
    return json.dumps(result, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    mcp.run()
