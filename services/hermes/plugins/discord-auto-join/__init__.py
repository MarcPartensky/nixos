"""Automatic entry of the bot into a Discord voice channel.

By default Hermes only enters voice on `/voice join`. This plugin wires
a native discord.py handler onto the Discord adapter via
``ctx.register_platform_handler``: as soon as an allowed member joins a
voice channel, the bot connects to it. The normal voice pipeline then takes over
(RTP receiver + listen loop + transcription + agent turn), because the
gateway already set ``_voice_input_callback`` at the adapter wiring
(gateway/run_adapters.py) and not only at the `/voice join` command.

The destination text channel for the transcriptions is essential: without it,
``GatewayVoiceMixin._handle_voice_channel_input`` drops the transcription
(``if not text_ch_id: return``). We take ``HERMES_DISCORD_VOICE_TEXT_CHANNEL``
if the variable is set, otherwise the voice channel itself (built-in chat of
voice channels, which discord.py 2.x accepts as a message destination).

No discord import at module level: plugins are loaded in ALL
Hermes processes (CLI, cron, subagents) and importing discord costs ~7 s in
this environment. The whole import therefore happens in the factory, which is called
only at the Discord adapter's connect().
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)

ALLOWED_ENV = "DISCORD_ALLOWED_USERS"
TEXT_CHANNEL_ENV = "HERMES_DISCORD_VOICE_TEXT_CHANNEL"


def _allowed_ids() -> set:
    """Allowed Discord ids (same variable as the adapter's text allowlist)."""
    raw = os.environ.get(ALLOWED_ENV, "")
    return {part.strip() for part in raw.replace(";", ",").split(",") if part.strip()}


def _text_channel_id(voice_channel: object) -> int:
    """Text channel to post transcriptions to: explicit env, otherwise the voice channel itself."""
    raw = (os.environ.get(TEXT_CHANNEL_ENV) or "").strip()
    if raw.isdigit():
        return int(raw)
    return int(getattr(voice_channel, "id"))


def _wire(native: object, adapter: object) -> None:
    """Factory called by the Discord adapter at connect(): ``(native bot, adapter)``."""
    if native is None:
        return

    async def on_voice_state_update(member, before, after):
        try:
            if getattr(member, "bot", False):
                return
            allowed = _allowed_ids()
            if allowed and str(member.id) not in allowed:
                return
            guild = member.guild
            if after.channel is not None and after.channel != before.channel:
                # Entry (or channel change): we join if the bot is not already in voice.
                if adapter.is_in_voice_channel(guild.id):
                    return
                joined = await adapter.join_voice_channel(
                    after.channel, text_channel_id=_text_channel_id(after.channel)
                )
                logger.info(
                    "discord-auto-join: entered %s (guild %s) after %s -> %s",
                    getattr(after.channel, "name", "?"), guild.id, member, joined,
                )
                return
            if after.channel is None:
                # Exit: we leave if nobody else is in the bot's channel.
                remaining = [
                    m for m in getattr(before.channel, "members", [])
                    if not getattr(m, "bot", False)
                ]
                if remaining:
                    return
                await adapter.leave_voice_channel(guild.id)
                logger.info(
                    "discord-auto-join: left %s (guild %s), nobody left",
                    getattr(before.channel, "name", "?"), guild.id,
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("discord-auto-join : %s", exc)

    native.add_listener(on_voice_state_update, "on_voice_state_update")
    logger.info("discord-auto-join: voice handler wired")


def register(ctx) -> None:
    """Plugin entry point."""
    ctx.register_platform_handler("discord", _wire)
