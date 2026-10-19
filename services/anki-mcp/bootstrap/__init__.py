"""Amorce le compte du serveur de sync pour l'instance headless AnkiMCP.

Anki n'expose aucun chemin non interactif pour renseigner « serveur de sync
personnalisé + compte + mot de passe » : la saisie passe par l'interface
graphique. Ce module le fait une fois au chargement du profil, puis persiste
la clé de sync (hkey) dans le profil, exactement comme le ferait
`aqt.sync` après un login réussi : c'est ce que lit ensuite `mw.pm.sync_auth()`,
donc l'outil `sync` de l'addon AnkiMCP.

Variables d'environnement attendues (posées par le service systemd) :
  ANKI_SYNC_USER           compte sur le serveur de sync
  ANKI_SYNC_ENDPOINT       URL du serveur, ex. https://anki.marcpartensky.com
  ANKI_SYNC_PASSWORD_FILE  fichier contenant le mot de passe (LoadCredential)

Idempotent : si le profil a déjà une clé de sync, rien n'est fait. La sync
automatique au démarrage est désactivée : la première mise en accord avec le
serveur (collection locale vide) demande une sync unidirectionnelle, et
l'assistant Anki l'affiche en boîte de dialogue modale, intenable sans écran.
C'est l'outil `sync` du serveur MCP qui pilote la sync, avec un choix de
direction explicite.
"""

import os

from aqt import gui_hooks, mw

_TAG = "[ankimcp-sync-bootstrap]"

# Évite d'empiler les tentatives si le profil est rouvert dans le même run.
_done = False


def _log(message: str) -> None:
    print(f"{_TAG} {message}", flush=True)


def _bootstrap() -> None:
    global _done
    if _done or mw is None or mw.col is None or mw.pm is None:
        return
    _done = True

    try:
        # Sans écran, une sync automatique qui tombe sur un conflit ouvre un
        # dialogue modal : on la désactive, l'agent déclenche la sync lui-même.
        if mw.pm.profile.get("autoSync"):
            mw.pm.profile["autoSync"] = False

        if mw.pm.profile.get("syncKey"):
            _log("profil déjà rattaché au serveur de sync, rien à faire")
            return

        user = os.environ.get("ANKI_SYNC_USER", "")
        endpoint = os.environ.get("ANKI_SYNC_ENDPOINT", "")
        password_file = os.environ.get("ANKI_SYNC_PASSWORD_FILE", "")
        if not (user and endpoint and password_file):
            _log("ANKI_SYNC_USER/ANKI_SYNC_ENDPOINT/ANKI_SYNC_PASSWORD_FILE "
                 "incomplets, amorçage ignoré")
            return

        with open(password_file, encoding="utf-8") as handle:
            password = handle.read().strip()

        auth = mw.col.sync_login(user, password, endpoint)
        mw.pm.set_sync_key(auth.hkey)
        mw.pm.set_sync_username(user)
        mw.pm.set_custom_sync_url(endpoint)
        _log(f"compte {user} rattaché à {endpoint}")
    except Exception as exc:  # réseau, identifiants, schéma : on réessaiera
        _done = False
        _log(f"amorçage échoué ({type(exc).__name__}: {exc})")


gui_hooks.profile_did_open.append(_bootstrap)
