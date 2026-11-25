"""Loop emoji 🔄 at the end of a Matrix message, and session renewal by reaction.

Two behaviors, wired via ``ctx.register_platform_handler`` (plugin API
supported, called by the Matrix adapter on its ``connect()``):

1. Every outgoing text message gets ``🔄`` on its own line at the end.
   That is the affordance: it is the emoji Marc reacts to.
2. A ``🔄`` reaction from an allowed user on a bot message calls
   ``GatewayRunner._handle_reset_command`` directly (the ``/new`` path,
   without the confirmation prompt) and returns the reset banner in the room.

Why not a patch of the nix package: the adapter lives in the store (read
only) and a ``postPatch`` would cost a full rebuild. The plugin
extension point is official, survives rebuilds (user directory) and re-applies
itself on every adapter reconnection.

No heavy import at module level: plugins are loaded in ALL Hermes
processes (CLI, cron, subagents), mautrix only makes sense at the gateway.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

EMOJI = "🔄"
_SEND_FLAG = "_loop_emoji_send_patched"


def _decorate(content: object) -> object:
    """Append the emoji at the end of the message, once only, without touching the rest."""
    if not isinstance(content, str):
        return content
    stripped = content.rstrip()
    if not stripped or stripped.endswith(EMOJI):
        return content
    return f"{stripped}\n\n{EMOJI}"


def _patch_send(adapter: object) -> None:
    """Wrap ``adapter.send`` once per adapter instance."""
    if getattr(adapter, _SEND_FLAG, False):
        return
    original = getattr(adapter, "send", None)
    if original is None:
        logger.warning("matrix-loop-emoji: adapter without a send method, emoji not applied")
        return

    async def send_with_loop_emoji(chat_id, content, *args, **kwargs):
        try:
            content = _decorate(content)
        except Exception:  # noqa: BLE001 - the emoji must never break a send
            pass
        return await original(chat_id, content, *args, **kwargs)

    try:
        adapter.send = send_with_loop_emoji
        setattr(adapter, _SEND_FLAG, True)
    except Exception as exc:  # noqa: BLE001
        logger.warning("matrix-loop-emoji: unable to patch send: %s", exc)


async def _renew_session(adapter: object, room_id: str, sender: str, reacts_to: str) -> None:
    """Renew the room session via the /new path (without confirmation)."""
    runner = getattr(adapter, "gateway_runner", None)
    if runner is None:
        logger.warning("matrix-loop-emoji: gateway_runner missing, reset impossible")
        return
    from gateway.platforms.event import MessageEvent, MessageType

    identity = await adapter._resolve_room_identity(room_id)
    display_name = ""
    try:
        display_name = await adapter._get_display_name(room_id, sender) or ""
    except Exception:  # noqa: BLE001
        pass
    source = adapter.build_source(
        chat_id=room_id,
        chat_name=identity.display_name,
        chat_type=identity.chat_type,
        user_id=sender,
        user_name=display_name,
        thread_id=None,
        chat_topic=identity.room_topic,
        guild_id=identity.server_name,
        message_id=str(reacts_to),
    )
    event = MessageEvent(
        text="/new",
        message_type=MessageType.COMMAND,
        source=source,
        user_id=sender,
        user_name=display_name,
        message_id=str(reacts_to),
    )
    result = await runner._handle_reset_command(event)
    if isinstance(result, str) and result.strip():
        await adapter.send(room_id, result)
    logger.info(
        "matrix-loop-emoji: session renewed in %s (reaction %s from %s on %s)",
        room_id, EMOJI, sender, reacts_to,
    )


async def _on_reaction(adapter: object, event: object) -> None:
    """Native mautrix handler: only does something on the 🔄 reaction."""
    content = getattr(event, "content", None)
    if not content:
        return
    relates = content.get("m.relates_to", {}) if isinstance(content, dict) else {}
    if not isinstance(relates, dict):
        return
    key = relates.get("key", "")
    reacts_to = relates.get("event_id", "")
    if key != EMOJI or not reacts_to:
        return
    sender = str(getattr(event, "sender", "") or "")
    own_id = str(getattr(adapter, "_user_id", "") or "")
    if not sender or sender == own_id:
        return
    allowed = getattr(adapter, "_allowed_user_ids", None) or set()
    if allowed and sender not in allowed:
        logger.info("matrix-loop-emoji: reaction ignored, %s not in allowlist", sender)
        return
    room_id = str(getattr(event, "room_id", "") or "")
    if not room_id:
        return
    try:
        if not await adapter._is_allowed_matrix_room_event(room_id):
            logger.info("matrix-loop-emoji: reaction ignored, room %s not allowed", room_id)
            return
    except Exception:  # noqa: BLE001 - no info, we continue
        pass
    await _renew_session(adapter, room_id, sender, str(reacts_to))


def _wire(native: object, adapter: object) -> None:
    """Factory called by the Matrix adapter at connect(): (mautrix client, adapter)."""
    if native is None:
        return
    _patch_send(adapter)
    try:
        from mautrix.types import EventType
    except Exception as exc:  # noqa: BLE001
        logger.warning("matrix-loop-emoji: mautrix unavailable (%s)", exc)
        return

    async def handler(event):
        try:
            await _on_reaction(adapter, event)
        except Exception as exc:  # noqa: BLE001
            logger.warning("matrix-loop-emoji: reaction handler failed: %s", exc)

    native.add_event_handler(EventType.REACTION, handler)
    logger.info("matrix-loop-emoji: emoji %s active (send + reaction)", EMOJI)


def register(ctx) -> None:
    """Plugin entry point."""
    ctx.register_platform_handler("matrix", _wire)
