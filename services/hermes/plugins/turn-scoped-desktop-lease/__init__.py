"""Turn-scoped active-session leases for the Desktop surface.

Hermes fences one live writer per stored conversation: a chat's first turn claims
an active-session lease in ``runtime/active_sessions.json`` and a Desktop record
keeps that lease for the whole life of its tab. It is released only after
``session_reaper._IDLE_LEASE_RELEASE_S`` (10 min) without activity, and never
while a turn runs -- while ``session.resume`` / ``session.activate`` refresh that
activity clock on every tab open. So a chat left open in one Desktop window
refuses every submit coming from another window with

    This chat is open in another Hermes window/terminal. Use it there, or start
    a new chat here.

for as long as the first window keeps the tab, even when both are idle.

This plugin narrows the fence to what it actually protects: the turn. At turn end
a liveness-tracked Desktop lease is released and ``_lease_idle_released`` is
stamped with the live session id, so an off-turn transcript writer (rewind, model
switch, manual compress) re-claims the slot before it writes, exactly like the
idle reaper's own release path. The next ``prompt.submit`` re-claims through
``_ensure_active_session_slot``, the same way the messaging gateway does per
turn. Two windows can then alternate on one chat; a submit while the other window
is mid-turn is still refused, which is the only case that could interleave two
writers on one transcript.

Why a plugin and not a patch of the Nix store: the package lives read-only in
``/nix/store`` (a ``postPatch`` would cost a full rebuild), the user-plugin
directory survives rebuilds, and the extension point is official. Same reasoning
as ``matrix-loop-emoji``. Delete this directory to restore the stock behaviour.

The wrapper REPLACES ``_release_hosted_room_turn_slot`` instead of calling it:
that helper's body is rebound onto ``server.py``'s globals at import time, so the
module-level copy cannot resolve ``_session_source`` on its own. Both branches of
the stock helper (hosted-room release, everything else) are reproduced here.
"""

from __future__ import annotations

import logging
import sys

logger = logging.getLogger(__name__)

_PATCHED = "_hermes_turn_scoped_desktop_lease"
_DESKTOP_SOURCES = frozenset({"desktop", "webui"})
_ROOM_SESSIONS = frozenset({"bot_room"})
_HOOK_NAME = "_release_hosted_room_turn_slot"


def _source_of(session: dict) -> str:
    try:
        from tui_gateway.session_workdir import _session_source

        return str(_session_source(session) or "").strip().lower()
    except Exception:  # noqa: BLE001 - a missing helper must not break a turn
        return ""


def _release_desktop_lease(session: dict) -> bool:
    """Drop this record's liveness-tracked lease and stamp it idle-released."""
    from tui_gateway import session_lifecycle as lifecycle

    lease = session.get("active_session_lease")
    if lease is None:
        return False
    if not getattr(lease, "track_liveness", False) or not getattr(lease, "enabled", True):
        return False
    if not lifecycle._release_active_session_slot(session):
        return False
    # Same writer identity the idle reaper records, so _reclaim_idle_released_lease
    # can re-claim for an off-turn write (rewind, model switch, /compress).
    session["_lease_idle_released"] = session.get("_sid") or session.get("session_key") or "desktop"
    return True


def install() -> None:
    """Install the turn-end hook (idempotent, best effort)."""
    try:
        from tui_gateway import session_lifecycle as lifecycle
    except Exception:  # noqa: BLE001 - CLI/cron/subagent processes have no gateway
        return

    if getattr(getattr(lifecycle, _HOOK_NAME, None), _PATCHED, False):
        return

    def _turn_scoped_release(session: dict) -> None:
        source = _source_of(session)
        try:
            if source in _DESKTOP_SOURCES:
                if _release_desktop_lease(session):
                    logger.debug("turn-scoped desktop lease released for %s", session.get("_sid"))
            elif source in _ROOM_SESSIONS:  # stock hosted-room behaviour
                lifecycle._release_active_session_slot(session)
        except Exception:  # noqa: BLE001 - never fail a turn over lease bookkeeping
            logger.debug("turn-scoped desktop lease: release failed", exc_info=True)

    setattr(_turn_scoped_release, _PATCHED, True)
    setattr(_turn_scoped_release, "__name__", _HOOK_NAME)
    setattr(_turn_scoped_release, "__doc__", "Release a turn's active-session slot (Desktop: turn-scoped).")

    setattr(lifecycle, _HOOK_NAME, _turn_scoped_release)
    # Turn bodies run rebound onto server.py's globals (method_ctx.bind_module), so the
    # call site resolves the name there: patch both, or the hook never runs.
    server = sys.modules.get("tui_gateway.server")
    if server is not None:
        setattr(server, _HOOK_NAME, _turn_scoped_release)
    logger.info("turn-scoped desktop lease installed")


def register(ctx=None) -> None:  # noqa: ANN001 - plugin entry point, context unused
    """Supported plugin entry point: same patch, so a lazy loader still applies it."""
    install()


install()
