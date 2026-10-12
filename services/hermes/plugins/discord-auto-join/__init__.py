"""Entree automatique du bot dans un salon vocal Discord.

Par defaut Hermes n'entre dans le vocal que sur `/voice join`. Ce plugin branche
un handler natif discord.py sur l'adaptateur Discord via
``ctx.register_platform_handler`` : des qu'un membre autorise rejoint un salon
vocal, le bot s'y connecte. Le pipeline vocal normal prend ensuite le relais
(receiver RTP + listen loop + transcription + tour d'agent), parce que le
gateway a deja pose ``_voice_input_callback`` au wiring de l'adaptateur
(gateway/run_adapters.py) et pas seulement a la commande `/voice join`.

Le salon texte de destination des transcriptions est indispensable : sans lui,
``GatewayVoiceMixin._handle_voice_channel_input`` jette la transcription
(``if not text_ch_id: return``). On prend ``HERMES_DISCORD_VOICE_TEXT_CHANNEL``
si la variable est posee, sinon le salon vocal lui-meme (chat integre des
salons vocaux, que discord.py 2.x accepte comme destination de message).

Aucun import discord au niveau module : les plugins sont charges dans TOUS les
process Hermes (CLI, cron, sous-agents) et importer discord y coute ~7 s dans
cet environnement. Tout l'import se fait donc dans la factory, qui n'est appelee
qu'au connect() de l'adaptateur Discord.
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)

ALLOWED_ENV = "DISCORD_ALLOWED_USERS"
TEXT_CHANNEL_ENV = "HERMES_DISCORD_VOICE_TEXT_CHANNEL"


def _allowed_ids() -> set:
    """Ids Discord autorises (meme variable que l'allowlist texte de l'adaptateur)."""
    raw = os.environ.get(ALLOWED_ENV, "")
    return {part.strip() for part in raw.replace(";", ",").split(",") if part.strip()}


def _text_channel_id(voice_channel: object) -> int:
    """Salon texte ou poster les transcriptions : env explicite, sinon le vocal lui-meme."""
    raw = (os.environ.get(TEXT_CHANNEL_ENV) or "").strip()
    if raw.isdigit():
        return int(raw)
    return int(getattr(voice_channel, "id"))


def _wire(native: object, adapter: object) -> None:
    """Factory appelee par l'adaptateur Discord au connect() : ``(bot natif, adaptateur)``."""
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
                # Entree (ou changement de salon) : on rejoint si le bot n'est pas deja en vocal.
                if adapter.is_in_voice_channel(guild.id):
                    return
                joined = await adapter.join_voice_channel(
                    after.channel, text_channel_id=_text_channel_id(after.channel)
                )
                logger.info(
                    "discord-auto-join : entree dans %s (guild %s) apres %s -> %s",
                    getattr(after.channel, "name", "?"), guild.id, member, joined,
                )
                return
            if after.channel is None:
                # Sortie : on quitte si plus personne d'autre n'est dans le salon du bot.
                remaining = [
                    m for m in getattr(before.channel, "members", [])
                    if not getattr(m, "bot", False)
                ]
                if remaining:
                    return
                await adapter.leave_voice_channel(guild.id)
                logger.info(
                    "discord-auto-join : sortie de %s (guild %s), plus personne",
                    getattr(before.channel, "name", "?"), guild.id,
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("discord-auto-join : %s", exc)

    native.add_listener(on_voice_state_update, "on_voice_state_update")
    logger.info("discord-auto-join : handler vocal branche")


def register(ctx) -> None:
    """Point d'entree du plugin."""
    ctx.register_platform_handler("discord", _wire)
