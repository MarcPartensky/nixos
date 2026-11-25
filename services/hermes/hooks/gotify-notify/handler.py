# Hook de gateway « gotify-notify » — sens Matrix -> Gotify du pont.
#
# Evenement : `agent:end` (le contexte porte platform, chat_id, message,
# response). On ne pousse que les tours termines DANS la salle du pont, donc
# les reponses de l'agent (y compris les resumes de cron livres dans cette
# salle) partent en notification Gotify, donc sur le telephone de marc via
# l'appli Gotify.
#
# Ce que ce hook ne fait PAS (volontairement) :
#   - les messages ENTRANTS de marc (`agent:start`) : il vient de les ecrire,
#     ce serait une notification en echo. Pour les pousser aussi, ajouter
#     "agent:start" a la liste `events` du HOOK.yaml : le contexte a la meme
#     forme (le texte entrant est dans `message` au lieu de `response`).
#   - les autres salles Matrix / plateformes : filtre sur chat_id == salle.
#
# Jeton : l'application Gotify creee par services/gotify-matrix
# (/var/lib/gotify-pont/application_token, 0400 hermes). Le hook tourne dans le
# process du gateway (utilisateur hermes), il peut donc le lire.
#
# Erreurs : jamais remontees au gateway (contrat des hooks), seulement
# journalisees dans le log du gateway + une ligne `gotify-notify:` visible.

import json
import os
import urllib.request


ROOM = os.environ.get("GOTIFY_PONT_ROOM", "!bHIbXBYEcLDiMFtbse:matrix.marcpartensky.com")
# Gotify vit sur le VPS depuis le 20/11/2026 : l'URL publique est la cible
# normale. Le repli loopback reste utile pendant une bascule (serveur encore
# local) et coute une seconde d'attente en cas d'echec.
GOTIFY_URL = os.environ.get("GOTIFY_PONT_URL", "https://gotify.marcpartensky.com")
GOTIFY_URL_FALLBACK = os.environ.get("GOTIFY_PONT_URL_FALLBACK", "http://127.0.0.1:8070")
TOKEN_FILE = os.environ.get("GOTIFY_PONT_APP_TOKEN_FILE", "/var/lib/gotify-pont/application_token")
PRIORITY = int(os.environ.get("GOTIFY_PONT_PRIORITY", "5"))
MAX_CHARS = 4000


def _context(args, kwargs):
    """Le chargeur appelle `handle(event_type, context)` ; on tolere aussi un
    appel en kwargs pour ne pas casser si le contrat evolue."""
    for value in list(args) + list(kwargs.values()):
        if isinstance(value, dict):
            return value
    return {}


def _token():
    with open(TOKEN_FILE, encoding="utf-8") as handle:
        return handle.read().strip()


def handle(*args, **kwargs):
    context = _context(args, kwargs)
    chat_id = str(context.get("chat_id") or "")
    text = str(context.get("response") or "").strip()
    if chat_id != ROOM:
        return
    if not text:
        return
    payload = {"title": "Hermes (Matrix)", "message": text[:MAX_CHARS], "priority": PRIORITY}
    last_exc = None
    for base in (GOTIFY_URL, GOTIFY_URL_FALLBACK):
        if not base:
            continue
        request = urllib.request.Request(
            base.rstrip("/") + "/message",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "X-Gotify-Key": _token()},
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                print("gotify-notify: pousse dans Gotify (%s, plateforme %s, salle %s) -> HTTP %s"
                      % (base, context.get("platform"), chat_id, response.status), flush=True)
                return
        except Exception as exc:  # noqa: BLE001 — un hook ne doit jamais casser un tour
            last_exc = exc
    print("gotify-notify: echec de la poussee Gotify : %s" % last_exc, flush=True)
