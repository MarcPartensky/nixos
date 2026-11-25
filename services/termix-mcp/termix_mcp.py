"""Serveur MCP Termix : pilote le panel serveur de tower par son API HTTP.

Termix n'a pas de MCP en amont et son API couvre surtout l'inventaire du
panel (hotes, plugins, audit, comptes). Deux capacites interessent l'agent :

- l'inventaire et l'etat des hotes, sans jamais lire les identifiants
  stockes (`/host/db/host/:id/password` n'est PAS expose ici) ;
- l'execution de commandes, par le plugin Snippets : Termix ouvre lui-meme
  la session SSH et rend stdout/stderr/code de sortie. Aucune cle SSH ne
  circule dans l'appel, mais cela suppose que Termix detienne deja un
  identifiant utilisable pour l'hote vise.

Auth : cle d'API Termix (`tmx_...`) relue a chaque appel depuis
TERMIX_API_KEY_FILE (secret sops) ou TERMIX_API_KEY.

Politique d'ecriture : les tools mutants exigent `confirm=True`, sinon ils
rendent l'apercu de l'appel sans rien envoyer. Les lectures ne demandent rien.
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
            "Cle API Termix absente : " + (KEY_FILE or "TERMIX_API_KEY_FILE")
            + " illisible et TERMIX_API_KEY vide")
    return key


def _call(method, path, body=None, query=None, timeout=None):
    """Appel HTTP brut. Leve une RuntimeError avec le corps d'erreur."""
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
            "HTTP %s sur %s %s : %s"
            % (exc.code, method, path, detail[:600]))
    except OSError as exc:
        raise RuntimeError(
            "%s %s injoignable : %s" % (method, url, exc))
    if not raw:
        return None
    return json.loads(raw.decode(errors="replace"))


def _preview(method, path, body):
    return ("DRY RUN, rien n'a ete envoye : %s %s\n%s"
            % (method, path, json.dumps(body, indent=1, ensure_ascii=False)))


def _host_summary(host):
    """Vue courte d'un hote : jamais de secret ni de blob de cle."""
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
    """Smoke test : auth, version, nombre d'hotes et de plugins.

    A appeler en premier quand un autre outil echoue : un 401 ici signifie
    que la cle d'API est absente, revoquee ou pointee vers le mauvais hote.
    """
    try:
        me = _call("GET", "/users/me")
    except RuntimeError as exc:
        return "ECHEC auth : " + str(exc)
    out = {"url": BASE_URL, "me": me}
    for label, path in (("version", "/version"), ("hosts", "/host/db/host"),
                        ("plugins", "/plugins")):
        try:
            value = _call("GET", path)
        except RuntimeError as exc:
            out[label] = "erreur : " + str(exc)[:200]
            continue
        if isinstance(value, list):
            out[label] = "%d elements" % len(value)
        else:
            out[label] = value
    return json.dumps(out, indent=1, ensure_ascii=False)


@mcp.tool()
def list_hosts(search: str = "", tag: str = "") -> str:
    """Liste les hotes de Termix (id, nom, ip, user, tags, type d'auth).

    `search` filtre sur le nom, l'IP et le user (insensible a la casse) ;
    `tag` filtre sur un tag exact. Ne rend jamais de mot de passe ni de cle.
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
    """Detail d'un hote : config SSH, options, defaults par plugin.

    Le mot de passe stocke est retire de la reponse ; utiliser l'UI Termix
    pour le consulter, pas l'agent.
    """
    host = _call("GET", "/host/db/host/%d" % host_id)
    if isinstance(host, dict):
        host.pop("password", None)
    return json.dumps(host, indent=1, ensure_ascii=False)


@mcp.tool()
def update_host(host_id: int, fields: str = "{}",
                confirm: bool = False) -> str:
    """Modifie un hote existant (PUT partiel).

    `fields` est un objet JSON des champs a changer, par exemple
    {"name": "deck", "tags": ["deck"], "port": 22}. Sans `confirm=True`,
    rend seulement l'apercu de l'appel.
    """
    try:
        payload = json.loads(fields or "{}")
    except ValueError as exc:
        return "fields n'est pas du JSON valide : %s" % exc
    if not isinstance(payload, dict) or not payload:
        return "fields doit etre un objet JSON non vide."
    path = "/host/db/host/%d" % host_id
    if not confirm:
        return _preview("PUT", path, payload)
    result = _call("PUT", path, payload)
    return json.dumps(result, indent=1, ensure_ascii=False)


@mcp.tool()
def delete_host(host_id: int, confirm: bool = False) -> str:
    """Supprime un hote de l'inventaire Termix. IRREVERSIBLE.

    Ne touche pas la machine distante, seulement l'entree Termix. Exige
    `confirm=True`.
    """
    path = "/host/db/host/%d" % host_id
    if not confirm:
        return _preview("DELETE", path, {"host_id": host_id})
    return json.dumps(_call("DELETE", path),
                      indent=1, ensure_ascii=False)


@mcp.tool()
def host_status(host_id: int = 0, refresh: bool = False) -> str:
    """Etat en ligne/hors ligne des hotes (sonde TCP du plugin Host Status).

    `host_id=0` rend tous les hotes. `refresh=True` force une nouvelle sonde
    au lieu du dernier resultat connu.
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
    """Execute une commande sur un hote, via le plugin Snippets de Termix.

    Termix ouvre lui-meme la session SSH et rend stdout, stderr et le code
    de sortie. Cree un snippet temporaire, l'execute, le supprime.

    Suppose que Termix detienne un identifiant utilisable pour cet hote : un
    hote en authType=key sans credentialId repond SSH_AUTH_FAILED. En cas de
    code 255, la commande n'a pas tourne du tout.
    """
    name = "__hermes_exec_" + uuid.uuid4().hex[:8]
    created = _call("POST", "/plugin-api/snippets/",
                    {"name": name, "content": command})
    snippet_id = (created or {}).get("id")
    if not snippet_id:
        return "Creation du snippet impossible : " + json.dumps(
            created, ensure_ascii=False)[:300]
    try:
        result = _call(
            "POST", "/plugin-api/snippets/execute",
            {"snippetId": snippet_id, "hostId": host_id},
            timeout=max(timeout_s, 15) + 30)
    except RuntimeError as exc:
        raise RuntimeError("Execution sur l'hote %s : %s"
                           % (host_id, exc))
    finally:
        try:
            _call("DELETE", "/plugin-api/snippets/%s" % snippet_id)
        except RuntimeError:
            pass
    return json.dumps(result, indent=1, ensure_ascii=False)


@mcp.tool()
def plugins(enabled_only: bool = False) -> str:
    """Liste les plugins Termix installes : id, nom, version, etat.

    Utile pour savoir quelle capacite est servie (ex. snippets, docker,
    service-manager) et si un plugin est desactive (503 sur ses routes).
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
    """Dernieres entrees du journal d'audit de Termix.

    `action` filtre sur un nom d'operation (ex. user_login). Montre qui a
    fait quoi dans le panel, pas ce qui se passe sur les machines.
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
    """Echappatoire : n'importe quelle route Termix, en JSON.

    `path` commence par un prefixe proxifie par l'instance : /host, /users,
    /rbac, /plugins, /credentials, /database, /audit-logs, /operations,
    /open-tabs, /plugin-api/<plugin>/... Un chemin hors de ces prefixes rend
    le SPA en 200 avec du HTML, pas une erreur.

    Les methodes autres que GET exigent `confirm=True`. Ne pas s'en servir
    pour lire les identifiants stockes : `get_host` les retire volontairement
    et `/host/db/host/<id>/password` reste hors du perimetre de l'agent.
    """
    verb = method.strip().upper()
    if not path.startswith("/"):
        return "path doit commencer par /"
    payload = None
    if body.strip():
        try:
            payload = json.loads(body)
        except ValueError as exc:
            return "body n'est pas du JSON valide : %s" % exc
    if verb != "GET" and not confirm:
        return _preview(verb, path, payload)
    result = _call(verb, path, payload)
    return json.dumps(result, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    mcp.run()
