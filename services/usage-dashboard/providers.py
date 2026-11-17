"""Registre des providers LLM : identite, nature de facturation, couleur.

Partage par les deux processus du dashboard :
  - agent_usage.py (utilisateur hermes) lit state.db et tague chaque ligne avec
    un ID de provider ;
  - usage_dashboard.py (utilisateur usage-dash) joint les soldes des API de
    facturation a ces memes IDs.
Sans fichier commun, les deux nommeraient les providers differemment et les
cartes de la page ne joindraient plus rien.

Un provider est identifie par son ID stable ("openrouter", "deepseek"...), pas
par son nom d'affichage : l'ID circule dans le JSON intermediaire et dans la
page. Le nom affiche et la couleur peuvent changer sans casser les donnees.

Nature de facturation (kind) :
  - "cash"         : credits prepayes, solde en devise, consommation au token.
  - "subscription" : forfait mensuel, les tokens ne sont pas factures un par un.
  - "local"        : modele servi sur une machine a soi, cout marginal nul.
  - "other"        : provider inconnu (ligne ancienne sans facturation) ou
                     nouveau provider non encore cartographie.
"""

from __future__ import annotations

# Ordre de declaration = ordre d'affichage par defaut a cout egal.
PROVIDERS: dict[str, dict] = {
    "openrouter": {
        "label": "OpenRouter",
        "kind": "cash",
        "color": "#cba6f7",
        "note": "credits prepayes, facture au token",
    },
    "deepseek": {
        "label": "DeepSeek direct",
        "kind": "cash",
        "color": "#89b4fa",
        "note": "compte direct, facture au token",
    },
    "moonshot": {
        "label": "Moonshot / Kimi",
        "kind": "cash",
        "color": "#94e2d5",
        "note": "compte direct Moonshot",
    },
    "anthropic": {
        "label": "Anthropic API",
        "kind": "cash",
        "color": "#eba0ac",
        "note": "compte API Anthropic, facture au token",
    },
    "claude-max": {
        "label": "Claude (abonnement)",
        "kind": "subscription",
        "color": "#fab387",
        "note": "abonnement mensuel, pas de cout au token",
    },
    "openai": {
        "label": "OpenAI",
        "kind": "cash",
        "color": "#a6e3a1",
        "note": "compte API OpenAI",
    },
    "local": {
        "label": "Local (GPU maison)",
        "kind": "local",
        "color": "#a6e3a1",
        "note": "llama-swap sur le laptop, cout marginal nul",
    },
    "unknown": {
        "label": "Non attribue",
        "kind": "other",
        "color": "#585b70",
        "note": "lignes anciennes sans provider de facturation enregistre",
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

# Familles de modeles : prefixe du slug -> (libelle, couleur).
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
    """ID de provider a partir du couple (provider, base_url) enregistre par Hermes.

    Hermes stocke le provider de facturation et l'URL de base qu'il a vraiment
    appelee. L'URL est la donnee la plus fiable (deux noms de provider peuvent
    pointer le meme compte), et elle arrive avec ou sans slash final : on ne
    compare jamais l'URL entiere, seulement des motifs.
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
    # Modeles servis sur une machine du reseau (laptop-llama, laptop-abl) :
    # le cout est nul, on ne cherche donc pas de solde.
    if "100.64.0.4" in hay or "127.0.0.1" in hay or "localhost" in hay:
        return "local"
    name = (provider or "").strip()
    if not name:
        return "unknown"
    return f"p:{name.lower()}"


def meta(pid: str) -> dict:
    """Fiche d'affichage d'un provider, y compris ceux non cartographies."""
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
        "note": "provider non cartographie",
    }


def family_of(model: str) -> tuple[str, str, str]:
    """(cle, libelle, couleur) de la famille d'un modele, d'apres son slug."""
    prefix = (model or "inconnu").split("/")[0].lower()
    if prefix in FAMILIES:
        label, color = FAMILIES[prefix]
        return prefix, label, color
    index = sum(ord(c) for c in prefix) % len(FALLBACK_COLORS)
    return prefix, prefix, FALLBACK_COLORS[index]
