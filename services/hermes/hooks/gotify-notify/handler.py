# Gateway hook "gotify-notify" - Matrix -> Gotify direction of the bridge.
#
# Event: `agent:end` (the context carries platform, chat_id, message,
# response). We only push completed turns IN the bridge room, so
# the agent responses (including cron summaries delivered in this
# room) go out as Gotify notifications, so to marc's phone via
# the Gotify app.
#
# What this hook does NOT do (on purpose):
#   - marc's INCOMING messages (`agent:start`): he just wrote them,
#     it would be an echo notification. To push them too, add
#     "agent:start" to the `events` list of HOOK.yaml: the context has the same
#     shape (the incoming text is in `message` instead of `response`).
#   - the other Matrix rooms / platforms: filter on chat_id == room.
#
# Token: the Gotify application created by services/gotify-matrix
# (/var/lib/gotify-pont/application_token, 0400 hermes). The hook runs in the
# gateway process (hermes user), so it can read it.
#
# Errors: never raised to the gateway (hook contract), only
# logged in the gateway log + a visible `gotify-notify:` line.

import json
import os
import urllib.request


ROOM = os.environ.get("GOTIFY_PONT_ROOM", "!bHIbXBYEcLDiMFtbse:matrix.marcpartensky.com")
# Gotify has lived on the VPS since 20/11/2026: the public URL is the normal
# target. The loopback fallback remains useful during a switchover (server still
# local) and costs a second of waiting on failure.
GOTIFY_URL = os.environ.get("GOTIFY_PONT_URL", "https://gotify.marcpartensky.com")
GOTIFY_URL_FALLBACK = os.environ.get("GOTIFY_PONT_URL_FALLBACK", "http://127.0.0.1:8070")
TOKEN_FILE = os.environ.get("GOTIFY_PONT_APP_TOKEN_FILE", "/var/lib/gotify-pont/application_token")
PRIORITY = int(os.environ.get("GOTIFY_PONT_PRIORITY", "5"))
MAX_CHARS = 4000


def _context(args, kwargs):
    """The loader calls `handle(event_type, context)`; we also tolerate a
    call with kwargs so as not to break if the contract evolves."""
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
                print("gotify-notify: pushed to Gotify (%s, platform %s, room %s) -> HTTP %s"
                      % (base, context.get("platform"), chat_id, response.status), flush=True)
                return
        except Exception as exc:  # noqa: BLE001 - a hook must never break a turn
            last_exc = exc
    print("gotify-notify: Gotify push failed: %s" % last_exc, flush=True)
