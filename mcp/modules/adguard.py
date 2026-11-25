"""AdGuard Home tools for mcp-host (/control API, stdlib only).

Why this module rather than a third-party MCP server: AdGuard already exposes
all its config and runtime over HTTP on /control, and mcp-host already serves
modules hot (FileSystemProvider). A 150-line file with no npm or node
dependency replaces an extra process.

Writes (filter list, clients, rewrites, DNS options) are EPHEMERAL:
the NixOS module runs with mutableSettings = false, so the YAML is regenerated on
every nixos-rebuild and everything written through the API disappears. The source of
truth remains services/adguard/default.nix. These tools are for runtime:
toggle protection, flush the cache, test an upstream, inspect a query.

Env: ADGUARD_URL (default http://127.0.0.1:3000), ADGUARD_USER, ADGUARD_PASS,
ADGUARD_TIMEOUT (default 8 s), ADGUARD_ALLOW_WRITES (default 1).
"""

import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request

try:
    from fastmcp.tools import tool
except Exception:  # test outside mcp-host: neutral decorator

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
    """Call the /control API and return the decoded JSON."""
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
        raise RuntimeError(f"AdGuard unreachable at {BASE}: {exc.reason}") from None


def _write_guard(what):
    if not ALLOW_WRITES:
        raise RuntimeError(f"write refused (ADGUARD_ALLOW_WRITES=0): {what}")


# ---------------------------------------------------------------- read


@tool
def adguard_status() -> dict:
    """AdGuard state: version, protection, DNS addresses, active filters."""
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
    """24 h stats: volume, blocked share, top domains and clients."""
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
    """Say whether a domain would be blocked and by which rule (without resolving it)."""
    return _call("/control/filtering/check_host?name=" + urllib.parse.quote(name, safe=""))


@tool
def adguard_filters() -> dict:
    """List the filter lists, their rule count and the manual rules."""
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
    """Configured clients (persistent IDs, exceptions, dedicated upstreams)."""
    return _call("/control/clients")


@tool
def adguard_rewrites() -> dict:
    """Local DNS rewrites (AdGuard's equivalent of /etc/hosts)."""
    return _call("/control/rewrite/list")


@tool
def adguard_blocked_services() -> dict:
    """Services blocked by ID (facebook, tiktok, ...)."""
    return _call("/control/blocked_services/get")


# ---------------------------------------------------------------- runtime


@tool
def adguard_protection(enable: bool) -> dict:
    """Turn filtering on or off at runtime (no rebuild, not persistent)."""
    _write_guard("protection")
    _call("/control/protection", {"enabled": bool(enable)})
    return {"protection_enabled": _call("/control/status").get("protection_enabled")}


@tool
def adguard_flush_cache() -> dict:
    """Flush AdGuard's DNS cache."""
    _write_guard("cache")
    _call("/control/cache_clear", {})
    return {"flushed": True}


@tool
def adguard_test_upstream(upstream: str, bootstrap: str = "1.1.1.1") -> dict:
    """Test one or more upstreams (comma-separated) and return OK or the error per server."""
    _write_guard("test")
    ups = [u.strip() for u in upstream.replace(",", " ").split() if u.strip()]
    boots = [b.strip() for b in bootstrap.replace(",", " ").split() if b.strip()]
    return _call(
        "/control/test_upstream_dns",
        {"upstream_dns": ups, "bootstrap_dns": boots, "private_upstream": []},
    )


@tool
def adguard_rewrite_add(domain: str, answer: str) -> dict:
    """Add a DNS rewrite (ephemeral: erased on the next rebuild)."""
    _write_guard("rewrite")
    _call("/control/rewrite/add", {"domain": domain, "answer": answer})
    return {"added": {"domain": domain, "answer": answer}}


@tool
def adguard_rewrite_remove(domain: str, answer: str) -> dict:
    """Remove an existing DNS rewrite."""
    _write_guard("rewrite")
    _call("/control/rewrite/delete", {"domain": domain, "answer": answer})
    return {"removed": {"domain": domain, "answer": answer}}


@tool
def adguard_querylog(limit: int = 20) -> dict:
    """Latest queries. Empty by config choice: querylog is disabled."""
    _write_guard("querylog")
    try:
        data = _call(f"/control/querylog?limit={int(limit)}")
    except RuntimeError as exc:
        return {"enabled": False, "detail": str(exc)}
    return {"enabled": True, "entries": (data.get("data") or [])[:limit]}
