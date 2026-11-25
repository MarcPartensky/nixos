"""OpenRouter profile that demands Zero Data Retention (ZDR) on every request.

Hermes forwards only ``sort/only/ignore/order/require_parameters/data_collection`` from
``provider_routing`` (agent/chat_completion_helpers._provider_preferences_for_agent), so OpenRouter's
per-request ``provider.zdr`` flag cannot be set from config even though the API accepts it
(https://openrouter.ai/docs/guides/features/zdr). This profile SHADOWS the bundled ``openrouter``
profile -- a ``$HERMES_HOME/plugins/model-providers/`` plugin wins on a name collision
(providers/__init__.py, register_provider) -- and adds ``zdr: true`` to the provider preferences of
every OpenRouter request, so OpenRouter only routes to endpoints with a Zero Data Retention policy.
"""
from __future__ import annotations

import dataclasses

from plugins.model_providers.openrouter import openrouter as _bundled
from providers import register_provider


class ZdrOpenRouterProfile(type(_bundled)):
    """The bundled OpenRouter profile plus a non-negotiable ZDR routing demand."""

    def build_extra_body(self, *, session_id=None, **context):
        body = super().build_extra_body(session_id=session_id, **context)
        prefs = dict(body.get("provider") or {})
        prefs["zdr"] = True
        prefs.setdefault("data_collection", "deny")
        body["provider"] = prefs
        return body


profile = ZdrOpenRouterProfile(
    **{f.name: getattr(_bundled, f.name) for f in dataclasses.fields(_bundled)}
)

register_provider(profile)
