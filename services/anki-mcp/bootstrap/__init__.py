"""Bootstraps the sync server account for the headless AnkiMCP instance.

Anki exposes no non-interactive path to set "custom sync server
+ account + password": the entry goes through the graphical
interface. This module does it once when the profile loads, then persists
the sync key (hkey) into the profile, exactly as `aqt.sync` would
after a successful login: this is what `mw.pm.sync_auth()` reads next,
hence the `sync` tool of the AnkiMCP addon.

Expected environment variables (set by the systemd service):
  ANKI_SYNC_USER           account on the sync server
  ANKI_SYNC_ENDPOINT       server URL, e.g. https://anki.marcpartensky.com
  ANKI_SYNC_PASSWORD_FILE  file containing the password (LoadCredential)

Idempotent: if the profile already has a sync key, nothing is done. Automatic
sync at startup is disabled: the first reconciliation with the
server (empty local collection) requires a one-way sync, and
the Anki wizard shows it in a modal dialog, unmanageable without a screen.
It is the `sync` tool of the MCP server that drives the sync, with an explicit
direction choice.
"""

import os

from aqt import gui_hooks, mw

_TAG = "[ankimcp-sync-bootstrap]"

# Avoids stacking attempts if the profile is reopened in the same run.
_done = False

# Retries after a failure: in a headless service the profile_did_open hook never
# fires again, so without them a transient failure (network at boot, sync server
# briefly unavailable) leaves the instance permanently unattached.
_retries_left = 8
_retry_delay_ms = 60_000


def _log(message: str) -> None:
    print(f"{_TAG} {message}", flush=True)


def _bootstrap() -> None:
    global _done, _retries_left
    if _done or mw is None or mw.col is None or mw.pm is None:
        return
    _done = True

    try:
        # Without a screen, an automatic sync that hits a conflict opens a
        # modal dialog: we disable it, the agent triggers the sync itself.
        if mw.pm.profile.get("autoSync"):
            mw.pm.profile["autoSync"] = False

        if mw.pm.profile.get("syncKey"):
            _log("profile already attached to the sync server, nothing to do")
            return

        user = os.environ.get("ANKI_SYNC_USER", "")
        endpoint = os.environ.get("ANKI_SYNC_ENDPOINT", "")
        password_file = os.environ.get("ANKI_SYNC_PASSWORD_FILE", "")
        if not (user and endpoint and password_file):
            _log("ANKI_SYNC_USER/ANKI_SYNC_ENDPOINT/ANKI_SYNC_PASSWORD_FILE "
                 "incomplete, bootstrap skipped")
            return

        with open(password_file, encoding="utf-8") as handle:
            password = handle.read().strip()

        auth = mw.col.sync_login(user, password, endpoint)
        mw.pm.set_sync_key(auth.hkey)
        mw.pm.set_sync_username(user)
        mw.pm.set_custom_sync_url(endpoint)
        _log(f"account {user} attached to {endpoint}")
    except Exception as exc:  # network, credentials, schema: we will retry
        _done = False
        _log(f"bootstrap failed ({type(exc).__name__}: {exc})")
        if _retries_left > 0:
            _retries_left -= 1
            _log(f"retry in {_retry_delay_ms // 1000} s "
                 f"({_retries_left} left)")
            try:
                from aqt.qt import QTimer

                QTimer.singleShot(_retry_delay_ms, _bootstrap)
            except Exception as timer_exc:  # no Qt: give up
                _log(f"cannot reschedule: {timer_exc}")


gui_hooks.profile_did_open.append(_bootstrap)
