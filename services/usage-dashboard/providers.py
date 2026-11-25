"""Registry of LLM providers: identity, billing nature, color.

Shared by the two dashboard processes:
  - agent_usage.py (hermes user) reads state.db and tags each line with
    a provider ID ;
  - usage_dashboard.py (usage-dash user) joins the balances of the billing
    APIs to these same IDs.
Without a common file, the two would name providers differently and the
page cards would no longer join anything.

A provider is identified by its stable ID ("openrouter", "deepseek"...), not
by its display name: the ID travels in the intermediate JSON and in the
page. The displayed name and the color can change without breaking the data.

Billing nature (kind):
  - "cash"         : prepaid credits, balance in currency, consumption per token.
  - "subscription" : monthly plan, tokens are not billed one by one.
  - "local"        : model served on a machine of your own, marginal cost zero.
  - "other"        : unknown provider (old line without billing) or
                     new provider not yet mapped.
"""

from __future__ import annotations

# Declaration order = default display order at equal cost.
PROVIDERS: dict[str, dict] = {
    "openrouter": {
        "label": "OpenRouter",
        "kind": "cash",
        "color": "#cba6f7",
        "note": "prepaid credits, billed per token",
    },
    "deepseek": {
        "label": "DeepSeek direct",
        "kind": "cash",
        "color": "#89b4fa",
        "note": "direct account, billed per token",
    },
    "moonshot": {
        "label": "Moonshot / Kimi",
        "kind": "cash",
        "color": "#94e2d5",
        "note": "direct Moonshot account",
    },
    "anthropic": {
        "label": "Anthropic API",
        "kind": "cash",
        "color": "#eba0ac",
        "note": "Anthropic API account, billed per token",
    },
    "claude-max": {
        "label": "Claude (subscription)",
        "kind": "subscription",
        "color": "#fab387",
        "note": "monthly subscription, no per-token cost",
    },
    "openai": {
        "label": "OpenAI",
        "kind": "cash",
        "color": "#a6e3a1",
        "note": "OpenAI API account",
    },
    # Google AI Studio: billed per token like the others, but NO balance
    # endpoint exists (the API only exposes the quota, not the remaining credit).
    # The dashboard therefore puts a health probe there instead of the balance.
    "gemini": {
        "label": "Google Gemini",
        "kind": "cash",
        "color": "#74c7ec",
        "note": "Google AI Studio, no balance endpoint (health probe)",
    },
    "local": {
        "label": "Local (home GPU)",
        "kind": "local",
        "color": "#a6e3a1",
        "note": "llama-swap on the laptop, marginal cost zero",
    },
    "unknown": {
        "label": "Unassigned",
        "kind": "other",
        "color": "#585b70",
        "note": "old lines with no recorded billing provider",
    },
}

FALLBACK_COLORS = [
    "#b4befe",
    "#89b4fa",
    "#94e2d5",
    "#f9e2af",
    "#fab387",
    "#f5c2e7",
    "#eba0ac",
    "#74c7ec",
]

# Model families: slug prefix -> (label, color).
FAMILIES = {
    "deepseek": ("DeepSeek", "#89b4fa"),
    "anthropic": ("Claude", "#fab387"),
    "moonshotai": ("Kimi", "#cba6f7"),
    "moonshot": ("Kimi", "#cba6f7"),
    "openai": ("ChatGPT", "#a6e3a1"),
    "google": ("Gemini", "#74c7ec"),
    "x-ai": ("Grok", "#f9e2af"),
    "qwen": ("Qwen", "#94e2d5"),
    "meta-llama": ("Llama", "#f5c2e7"),
    "mistralai": ("Mistral", "#eba0ac"),
    "nvidia": ("Nvidia", "#b4befe"),
    "z-ai": ("Z.ai", "#89dceb"),
    "minimax": ("MiniMax", "#f2cdcd"),
    "amazon": ("Amazon", "#f5e0dc"),
    "cohere": ("Cohere", "#f38ba8"),
    "thinkingmachines": ("Inkling", "#f9e2af"),
}


def normalize(provider: str, base_url: str) -> str:
    """Provider ID from the (provider, base_url) pair recorded by Hermes.

    Hermes stores the billing provider and the base URL it really
    called. The URL is the most reliable datum (two provider names can
    point to the same account), and it arrives with or without a trailing
    slash: the whole URL is never compared, only patterns.
    """
    hay = f"{provider or ''} {base_url or ''}".lower()
    if "openrouter" in hay:
        return "openrouter"
    if "claude-subscription" in hay:
        return "claude-max"
    if "deepseek" in hay:
        return "deepseek"
    if "moonshot" in hay or "kimi" in hay:
        return "moonshot"
    if "anthropic" in hay:
        return "anthropic"
    if "openai.com" in hay:
        return "openai"
    # Hermes' built-in gemini provider (Google AI Studio): the provider name
    # and the base URL both point to Google.
    if "gemini" in hay or "generativelanguage" in hay:
        return "gemini"
    # Models served on a machine of the network (laptop-llama, laptop-abl):
    # the cost is zero, so no balance is looked up.
    if "100.64.0.4" in hay or "127.0.0.1" in hay or "localhost" in hay:
        return "local"
    name = (provider or "").strip()
    if not name:
        return "unknown"
    return f"p:{name.lower()}"


def meta(pid: str) -> dict:
    """Display record of a provider, including unmapped ones."""
    known = PROVIDERS.get(pid)
    if known:
        return {"id": pid, **known}
    label = pid[2:] if pid.startswith("p:") else pid
    index = sum(ord(c) for c in pid) % len(FALLBACK_COLORS)
    return {
        "id": pid,
        "label": label,
        "kind": "other",
        "color": FALLBACK_COLORS[index],
        "note": "unmapped provider",
    }


def family_of(model: str) -> tuple[str, str, str]:
    """(key, label, color) of a model's family, based on its slug."""
    prefix = (model or "unknown").split("/")[0].lower()
    if prefix in FAMILIES:
        label, color = FAMILIES[prefix]
        return prefix, label, color
    index = sum(ord(c) for c in prefix) % len(FALLBACK_COLORS)
    return prefix, prefix, FALLBACK_COLORS[index]
