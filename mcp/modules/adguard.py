"""Outils AdGuard Home pour mcp-host (API /control, stdlib seule).

Pourquoi ce module plutot qu'un serveur MCP tiers : AdGuard expose deja toute
sa config et son runtime en HTTP sur /control, et mcp-host sert deja les
modules a chaud (FileSystemProvider). Un fichier de 150 lignes sans dependance
npm ni node remplace un process supplementaire.

Les ecritures (liste de filtres, clients, rewrites, options DNS) sont EPHEMERES :
le module NixOS tourne en mutableSettings = false, donc le YAML est regenere a
chaque nixos-rebuild et tout ce qui est ecrit par l'API disparait. La source de
verite reste services/adguard/default.nix. Ces outils servent au runtime :
basculer la protection, purger le cache, tester un amont, inspecter une requete.

Env : ADGUARD_URL (defaut http://127.0.0.1:3000), ADGUARD_USER, ADGUARD_PASS,
ADGUARD_TIMEOUT (defaut 8 s), ADGUARD_ALLOW_WRITES (defaut 1).
"""

import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request

try:
    from fastmcp.tools import tool
except Exception:  # test hors mcp-host : decorateur neutre

    def tool(fn=None, **_kw):
        if fn is not None:
            return fn
        return lambda f: f


BASE = os.environ.get("ADGUARD_URL", "http://127.0.0.1:3000").rstrip("/")
USER = os.environ.get("ADGUARD_USER", "")
PASSWORD = os.environ.get("ADGUARD_PASS", "")
TIMEOUT = float(os.environ.get("ADGUARD_TIMEOUT", "8"))
ALLOW_WRITES = os.environ.get("ADGUARD_ALLOW_WRITES", "1") not in ("0", "false", "")


def _call(path, payload=None, method=None):
    """Appelle l'API /control et rend le JSON decode."""
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        BASE + path, data=data, method=method or ("POST" if data is not None else "GET")
    )
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if USER:
        token = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        req.add_header("Authorization", "Basic " + token)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise RuntimeError(f"AdGuard {path} -> HTTP {exc.code} {detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"AdGuard injoignable sur {BASE}: {exc.reason}") from None


def _write_guard(what):
    if not ALLOW_WRITES:
        raise RuntimeError(f"ecriture refusee (ADGUARD_ALLOW_WRITES=0): {what}")


# ---------------------------------------------------------------- lecture


@tool
def adguard_status() -> dict:
    """Etat d'AdGuard : version, protection, adresses DNS, filtres actifs."""
    st = _call("/control/status")
    filt = _call("/control/filtering/status")
    return {
        "version": st.get("version"),
        "protection_enabled": st.get("protection_enabled"),
        "dns_addresses": st.get("dns_addresses"),
        "running": st.get("running"),
        "filters": [
            {"name": f.get("name"), "rules": f.get("rules_count"), "enabled": f.get("enabled")}
            for f in filt.get("filters", [])
        ],
        "user_rules": len(filt.get("user_rules") or []),
        "query_log_enabled": st.get("querylog_enabled"),
    }


@tool
def adguard_stats(top: int = 5) -> dict:
    """Statistiques 24 h : volume, part bloquee, top domaines et clients."""
    s = _call("/control/stats")

    def total(key):
        return sum(s.get(key) or [])

    queries, blocked = total("dns_queries"), total("blocked_filtering")
    return {
        "queries": queries,
        "blocked": blocked,
        "blocked_pct": round(100 * blocked / queries, 2) if queries else 0.0,
        "avg_processing_ms": round((s.get("avg_processing_time") or 0) * 1000, 3),
        "top_domains": (s.get("top_queried_domains") or [])[:top],
        "top_blocked": (s.get("top_blocked_domains") or [])[:top],
        "top_clients": (s.get("top_clients") or [])[:top],
        "upstreams": (s.get("top_upstreams_responses") or [])[:top],
    }


@tool
def adguard_check_host(name: str) -> dict:
    """Dit si un domaine serait bloque et par quelle regle (sans le resoudre)."""
    return _call("/control/filtering/check_host?name=" + urllib.parse.quote(name, safe=""))


@tool
def adguard_filters() -> dict:
    """Liste les listes de filtres, leur nombre de regles et les regles manuelles."""
    st = _call("/control/filtering/status")
    return {
        "filters": [
            {
                "id": f.get("id"),
                "name": f.get("name"),
                "url": f.get("url"),
                "rules": f.get("rules_count"),
                "enabled": f.get("enabled"),
                "last_updated": f.get("last_updated"),
            }
            for f in st.get("filters", [])
        ],
        "user_rules": st.get("user_rules") or [],
        "interval_hours": st.get("interval"),
    }


@tool
def adguard_clients() -> dict:
    """Clients configures (identifiants persistants, exceptions, upstreams dedies)."""
    return _call("/control/clients")


@tool
def adguard_rewrites() -> dict:
    """Reecritures DNS locales (equivalent de /etc/hosts cote AdGuard)."""
    return _call("/control/rewrite/list")


@tool
def adguard_blocked_services() -> dict:
    """Services bloques par identifiant (facebook, tiktok, ...)."""
    return _call("/control/blocked_services/get")


# ---------------------------------------------------------------- runtime


@tool
def adguard_protection(enable: bool) -> dict:
    """Active ou coupe le filtrage a chaud (sans rebuild, non persistant)."""
    _write_guard("protection")
    _call("/control/protection", {"enabled": bool(enable)})
    return {"protection_enabled": _call("/control/status").get("protection_enabled")}


@tool
def adguard_flush_cache() -> dict:
    """Vide le cache DNS d'AdGuard."""
    _write_guard("cache")
    _call("/control/cache_clear", {})
    return {"flushed": True}


@tool
def adguard_test_upstream(upstream: str, bootstrap: str = "1.1.1.1") -> dict:
    """Teste un ou des amonts (separes par des virgules) et rend OK ou l'erreur par serveur."""
    _write_guard("test")
    ups = [u.strip() for u in upstream.replace(",", " ").split() if u.strip()]
    boots = [b.strip() for b in bootstrap.replace(",", " ").split() if b.strip()]
    return _call(
        "/control/test_upstream_dns",
        {"upstream_dns": ups, "bootstrap_dns": boots, "private_upstream": []},
    )


@tool
def adguard_rewrite_add(domain: str, answer: str) -> dict:
    """Ajoute une reecriture DNS (ephemere : effacee au prochain rebuild)."""
    _write_guard("rewrite")
    _call("/control/rewrite/add", {"domain": domain, "answer": answer})
    return {"added": {"domain": domain, "answer": answer}}


@tool
def adguard_rewrite_remove(domain: str, answer: str) -> dict:
    """Retire une reecriture DNS existante."""
    _write_guard("rewrite")
    _call("/control/rewrite/delete", {"domain": domain, "answer": answer})
    return {"removed": {"domain": domain, "answer": answer}}


@tool
def adguard_querylog(limit: int = 20) -> dict:
    """Dernieres requetes. Vide par choix de conf : querylog est desactive."""
    _write_guard("querylog")
    try:
        data = _call(f"/control/querylog?limit={int(limit)}")
    except RuntimeError as exc:
        return {"enabled": False, "detail": str(exc)}
    return {"enabled": True, "entries": (data.get("data") or [])[:limit]}
