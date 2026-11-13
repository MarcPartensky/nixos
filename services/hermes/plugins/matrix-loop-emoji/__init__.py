"""Emoji de boucle 🔄 en fin de message Matrix, et renouvellement de session par réaction.

Deux comportements, branchés via ``ctx.register_platform_handler`` (API plugin
supportée, appelée par l'adaptateur Matrix à son ``connect()``) :

1. Chaque message texte sortant reçoit ``🔄`` sur sa propre ligne à la fin.
   C'est l'affordance : c'est l'emoji sur lequel Marc réagit.
2. Une réaction ``🔄`` d'un utilisateur autorisé sur un message du bot appelle
   directement ``GatewayRunner._handle_reset_command`` (le chemin de ``/new``,
   sans la demande de confirmation) et renvoie la bannière de reset dans le salon.

Pourquoi pas un patch du paquet nix : l'adaptateur vit dans le store (lecture
seule) et un ``postPatch`` coûterait un rebuild complet. Le point d'extension
plugin est officiel, survit aux rebuilds (répertoire utilisateur) et se ré-applique
tout seul à chaque reconnexion de l'adaptateur.

Aucun import lourd au niveau module : les plugins sont chargés dans TOUS les
process Hermes (CLI, cron, sous-agents), mautrix n'a de sens qu'au gateway.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

EMOJI = "🔄"
_SEND_FLAG = "_loop_emoji_send_patched"


def _decorate(content: object) -> object:
    """Ajoute l'emoji en fin de message, une seule fois, sans toucher au reste."""
    if not isinstance(content, str):
        return content
    stripped = content.rstrip()
    if not stripped or stripped.endswith(EMOJI):
        return content
    return f"{stripped}\n\n{EMOJI}"


def _patch_send(adapter: object) -> None:
    """Enveloppe ``adapter.send`` une seule fois par instance d'adaptateur."""
    if getattr(adapter, _SEND_FLAG, False):
        return
    original = getattr(adapter, "send", None)
    if original is None:
        logger.warning("matrix-loop-emoji : adaptateur sans méthode send, emoji non appliqué")
        return

    async def send_with_loop_emoji(chat_id, content, *args, **kwargs):
        try:
            content = _decorate(content)
        except Exception:  # noqa: BLE001 - l'emoji ne doit jamais casser un envoi
            pass
        return await original(chat_id, content, *args, **kwargs)

    try:
        adapter.send = send_with_loop_emoji
        setattr(adapter, _SEND_FLAG, True)
    except Exception as exc:  # noqa: BLE001
        logger.warning("matrix-loop-emoji : impossible de patcher send : %s", exc)


async def _renew_session(adapter: object, room_id: str, sender: str, reacts_to: str) -> None:
    """Renouvelle la session du salon via le chemin de /new (sans confirmation)."""
    runner = getattr(adapter, "gateway_runner", None)
    if runner is None:
        logger.warning("matrix-loop-emoji : gateway_runner absent, reset impossible")
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
        "matrix-loop-emoji : session renouvelée dans %s (réaction %s de %s sur %s)",
        room_id, EMOJI, sender, reacts_to,
    )


async def _on_reaction(adapter: object, event: object) -> None:
    """Handler natif mautrix : ne fait quelque chose que sur la réaction 🔄."""
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
        logger.info("matrix-loop-emoji : réaction ignorée, %s hors allowlist", sender)
        return
    room_id = str(getattr(event, "room_id", "") or "")
    if not room_id:
        return
    try:
        if not await adapter._is_allowed_matrix_room_event(room_id):
            logger.info("matrix-loop-emoji : réaction ignorée, salon %s non autorisé", room_id)
            return
    except Exception:  # noqa: BLE001 - pas d'info, on continue
        pass
    await _renew_session(adapter, room_id, sender, str(reacts_to))


def _wire(native: object, adapter: object) -> None:
    """Factory appelée par l'adaptateur Matrix au connect() : (client mautrix, adaptateur)."""
    if native is None:
        return
    _patch_send(adapter)
    try:
        from mautrix.types import EventType
    except Exception as exc:  # noqa: BLE001
        logger.warning("matrix-loop-emoji : mautrix indisponible (%s)", exc)
        return

    async def handler(event):
        try:
            await _on_reaction(adapter, event)
        except Exception as exc:  # noqa: BLE001
            logger.warning("matrix-loop-emoji : handler réaction en échec : %s", exc)

    native.add_event_handler(EventType.REACTION, handler)
    logger.info("matrix-loop-emoji : emoji %s actif (envoi + réaction)", EMOJI)


def register(ctx) -> None:
    """Point d'entrée du plugin."""
    ctx.register_platform_handler("matrix", _wire)
