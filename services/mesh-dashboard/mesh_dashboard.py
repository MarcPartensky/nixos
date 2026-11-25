#!/usr/bin/env python3
"""Dashboard of the tailnet (headscale) nodes seen from tower.

Single source: `tailscale status --json` (mesh client, socket
/var/run/tailscale/tailscaled.sock, readable by the service user) and
`tailscale ping` to measure the real path of each online peer.

No dependency: stdlib only. Serves an HTML page (polling /api/nodes)
and the raw JSON. Latency is measured in a background task, never in an
HTTP request, so that the page stays instant even if a peer does not respond.

Each measurement cycle is timestamped: the page shows the age of the last check
per node, and the state (online / offline, last seen online at)
is persisted to disk to survive a service restart.

Gotify notifications on online -> offline transition and the reverse (plus a
message at startup). The token comes from a file (sops secret); without a token
the service still measures, and the journal says so.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("MESH_DASHBOARD_HOST", "0.0.0.0")
PORT = int(os.environ.get("MESH_DASHBOARD_PORT", "9140"))
STATE_FILE = os.environ.get("MESH_DASHBOARD_STATE", "/var/lib/mesh-dashboard/state.json")
GOTIFY_URL = os.environ.get("MESH_DASHBOARD_GOTIFY_URL", "http://127.0.0.1:8070").rstrip("/")
GOTIFY_TOKEN_FILE = os.environ.get("MESH_DASHBOARD_GOTIFY_TOKEN_FILE", "")
# Devices expected in the tailnet but not yet enrolled (comma-separated
# list): the page shows them as "pending" instead of forgetting them.
EXPECTED = [n.strip().lower() for n in os.environ.get("MESH_DASHBOARD_EXPECTED", "").split(",") if n.strip()]
# Snapshot of the tunnel health probe (services/tunnel-health, unit
# tunnel-health-probe on tower). The dashboard measures no tunnel itself:
# it rereads this file and shows a dedicated section at the bottom of the page.
TUNNELS_STATE = os.environ.get("MESH_DASHBOARD_TUNNELS_STATE", "/var/lib/tunnel-health/status.json")
TUNNELS_TTL = 2.0       # read cache of the snapshot
TUNNELS_STALE = 180     # beyond, the section flags stale data

STATUS_TTL = 3.0        # cache of `tailscale status`
PING_INTERVAL = 20.0    # period of the latency measurer
PING_TIMEOUT = "2s"

_lock = threading.Lock()
_state: dict = {
    "status": None,
    "status_at": 0.0,
    "pings": {},
    "cycle_at": 0.0,
    # id -> {label, online, last_online, down_since, last_check, cycles}
    "history": {},
}


# --------------------------------------------------------------------------
# persistence (timestamps only)
# --------------------------------------------------------------------------

def _load_history() -> None:
    try:
        with open(STATE_FILE) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return  # first start: nothing to load
    if isinstance(data.get("history"), dict):
        with _lock:
            _state["history"] = {str(k): v for k, v in data["history"].items()}


def _save_history() -> None:
    with _lock:
        payload = {"saved": time.time(), "cycle_at": _state["cycle_at"], "history": _state["history"]}
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = f"{STATE_FILE}.tmp"
        with open(tmp, "w") as fh:
            json.dump(payload, fh)
        os.replace(tmp, STATE_FILE)
    except OSError as exc:
        print(f"state not written: {exc}", flush=True)


# --------------------------------------------------------------------------
# Gotify
# --------------------------------------------------------------------------

def _gotify_token() -> str | None:
    if not GOTIFY_TOKEN_FILE:
        return None
    try:
        with open(GOTIFY_TOKEN_FILE) as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def notify(title: str, message: str, priority: int = 5) -> bool:
    """POST /message on Gotify. A failed notification must never break the measurement."""
    token = _gotify_token()
    if not token:
        print(f"notification skipped (no Gotify token): {title}", flush=True)
        return False
    body = json.dumps({"title": title, "message": message, "priority": priority}).encode()
    req = urllib.request.Request(
        f"{GOTIFY_URL}/message",
        data=body,
        headers={"Content-Type": "application/json", "X-Gotify-Key": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            print(f"Gotify notification '{title}' -> {resp.status}", flush=True)
            return 200 <= resp.status < 300
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        print(f"Gotify notification failed ({title}): {exc}", flush=True)
        return False


# --------------------------------------------------------------------------
# collection
# --------------------------------------------------------------------------

def _run(cmd: list[str], timeout: float = 10.0) -> str:
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout, check=False
    ).stdout


def _status() -> dict:
    """`tailscale status --json`, with a short cache (peers change little)."""
    now = time.monotonic()
    with _lock:
        if _state["status"] is not None and now - _state["status_at"] < STATUS_TTL:
            return _state["status"]
    try:
        raw = _run(["tailscale", "status", "--json"], timeout=8)
        data = json.loads(raw) if raw.strip() else {}
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        data = {}
    with _lock:
        _state["status"] = data
        _state["status_at"] = time.monotonic()
    return data


def _ping(ip: str) -> dict:
    """Latency + path (`via 192.168.1.31:41641` or `via DERP(vps)`).

    We ping the mesh IP, never the name: a node's HostName may differ
    from its MagicDNS name (the laptop is called `nixos` locally but `laptop` on
    the controller), and `tailscale ping nixos` then resolves nothing.
    """
    try:
        out = _run(["tailscale", "ping", "-c", "1", "--timeout", PING_TIMEOUT, ip], timeout=6)
    except (subprocess.SubprocessError, OSError):
        return {"ok": False}
    if "pong from" not in out:
        return {"ok": False}
    ms = re.search(r"in ([\d.]+)ms", out)
    via = re.search(r"via ([^\s,]+)", out)
    return {
        "ok": True,
        "ms": float(ms.group(1)) if ms else None,
        "via": via.group(1) if via else None,
        "direct": bool(via and "DERP" not in via.group(1)),
    }


def _label(peer: dict) -> str:
    dns = (peer.get("DNSName") or "").rstrip(".")
    return (dns.split(".")[0] if dns else "") or peer.get("HostName") or "?"


def _track(key: str, label: str, online: bool, checked_at: float) -> dict:
    """Updates a node's history and notifies the transitions."""
    with _lock:
        hist = _state["history"].setdefault(key, {})
        previous = hist.get("online")
        hist["label"] = label
        hist["last_check"] = checked_at
        hist["cycles"] = int(hist.get("cycles") or 0) + 1
        if online:
            hist["last_online"] = checked_at
            hist["down_since"] = None
        else:
            if previous is True or "down_since" not in hist:
                hist["down_since"] = hist.get("down_since") or checked_at
        hist["online"] = online
        snapshot = dict(hist)
    if previous is not None and previous != online:
        if online:
            down = snapshot.get("down_since")
            suffix = ""
            if down:
                mins = (checked_at - float(down)) / 60
                suffix = f" (gone {mins:.0f} min)" if mins >= 1 else ""
            notify(f"mesh: {label} back online", f"{label} ({key}) responds to the mesh again{suffix}.", 5)
        else:
            notify(
                f"mesh: {label} offline",
                f"{label} ({key}) no longer responds to the mesh ping.",
                8,
            )
    return snapshot


def _cycle() -> None:
    """One measurement cycle: controller status + ping of each online peer."""
    data = _status()
    peers = list((data.get("Peer") or {}).values())
    now = time.time()
    pings: dict[str, dict] = {}
    for peer in peers:
        ips = peer.get("TailscaleIPs") or []
        if not ips:
            continue
        key = str(peer.get("ID") or ips[0])
        result: dict = {"ok": False}
        if peer.get("Online"):
            result = _ping(ips[0])
        # the ping is authoritative: a peer "online" on the controller side but silent is
        # counted offline (case of a network-blocked node, or a frozen tailscaled)
        pings[key] = result
        _track(key, _label(peer), bool(peer.get("Online")) and bool(result.get("ok")), now)
    with _lock:
        _state["pings"] = pings
        _state["cycle_at"] = now
    _save_history()


def _pinger() -> None:
    first = True
    while True:
        try:
            data = _status()
            if first:
                peers = list((data.get("Peer") or {}).values())
                notify(
                    "mesh: dashboard started",
                    f"Monitoring of {len(peers)} tailnet node(s) resumed.",
                    2,
                )
                backend = data.get("BackendState") or "?"
                if backend != "Running":
                    notify("mesh: tower is not connected", f"tailscaled is in state '{backend}'.", 8)
                first = False
            _cycle()
        except Exception as exc:  # a disappearing peer must not kill the loop
            print(f"cycle failed: {exc!r}", flush=True)
        time.sleep(PING_INTERVAL)


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def _node(peer: dict, self_node: bool = False) -> dict:
    ips = peer.get("TailscaleIPs") or []
    ip4 = next((ip for ip in ips if ":" not in ip), None)
    ip6 = next((ip for ip in ips if ":" in ip), None)
    relay = peer.get("Relay") or None
    cur_addr = peer.get("CurAddr") or None
    online = bool(peer.get("Online"))
    if self_node:
        path = "local"
    elif not online:
        path = "offline"
    elif cur_addr:
        path = f"direct {cur_addr}"
    elif relay:
        path = f"DERP relay {relay}"
    else:
        path = "unknown"
    key = str(peer.get("ID") or ip4 or peer.get("HostName"))
    with _lock:
        ping = dict(_state["pings"].get(key) or {})
        hist = dict(_state["history"].get(key) or {})
        cycle_at = _state["cycle_at"] or None
    dns = (peer.get("DNSName") or "").rstrip(".")
    # The controller sometimes renames a node (laptop) without the local HostName
    # following (nixos): the reference name is the MagicDNS one.
    label = dns.split(".")[0] if dns else ""
    if self_node:
        # for tower, "seen online" = the current cycle
        hist["last_check"] = hist.get("last_check") or cycle_at
    return {
        "id": key,
        "host": label or peer.get("HostName") or ip4,
        "hostname": peer.get("HostName") or "",
        "dns": dns,
        "os": peer.get("OS") or "?",
        "ip4": ip4,
        "ip6": ip6,
        "online": online,
        "self": self_node,
        "active": bool(peer.get("Active")),
        "path": path,
        "direct": bool(cur_addr),
        "relay": relay,
        "rx": peer.get("RxBytes") or 0,
        "tx": peer.get("TxBytes") or 0,
        "created": peer.get("Created") or None,
        "exit_node": bool(peer.get("ExitNode")),
        "ping": ping,
        "last_check": hist.get("last_check"),
        "last_online": hist.get("last_online") or (cycle_at if self_node else None),
        "down_since": hist.get("down_since"),
        "cycles": hist.get("cycles"),
    }


def _tunnels() -> dict:
    """Section "tunnels": snapshot of the services/tunnel-health probe.

    The probe (unit tunnel-health-probe, every 60 s) writes a status.json
    per alias with its real state: SSH banner read via the alias path
    (LAN, tower loopback, or VPS loopback for the reverse tunnels).
    Here we measure nothing, we reread - and we say so when the file is missing or
    when it is too old, rather than showing an invented state.
    """
    now = time.monotonic()
    with _lock:
        cached = _state.get("tunnels")
        cached_at = _state.get("tunnels_at") or 0.0
    if cached is not None and now - cached_at < TUNNELS_TTL:
        return cached
    try:
        with open(TUNNELS_STATE) as fh:
            raw = json.load(fh)
    except (OSError, json.JSONDecodeError):
        data: dict = {"available": False}
    else:
        aliases = raw.get("aliases") or {}
        # module declaration order; fallback to alphabetical order for
        # a snapshot written by a probe older than the metadata addition
        meta = raw.get("endpoints") or [{"alias": a} for a in sorted(aliases)]
        rows = []
        for ep in meta:
            alias = ep.get("alias") or ""
            entry = aliases.get(alias) or {}
            status = entry.get("status") or "unknown"
            rows.append({
                "alias": alias,
                "target": ep.get("target") or "",
                "purpose": ep.get("purpose") or "",
                "via": ep.get("via") or "",
                "status": status,
                "latency_ms": entry.get("latency_ms"),
                "detail": entry.get("detail") or "",
                "since": entry.get("since"),
                "last_ok": entry.get("last_ok"),
            })
        checked = raw.get("checked_at")
        age = round(time.time() - checked, 1) if checked else None
        data = {
            "available": True,
            "checked_at": checked,
            "age": age,
            "stale": bool(age is None or age > TUNNELS_STALE),
            "rack_error": raw.get("rack_error") or "",
            "duration_ms": raw.get("duration_ms"),
            "counts": {
                "total": len(rows),
                "up": sum(1 for r in rows if r["status"] == "up"),
                "down": sum(1 for r in rows if r["status"] == "down"),
                "unknown": sum(1 for r in rows if r["status"] not in ("up", "down")),
            },
            "rows": rows,
        }
    with _lock:
        _state["tunnels"] = data
        _state["tunnels_at"] = now
    return data


def snapshot() -> dict:
    data = _status()
    nodes = []
    me = data.get("Self")
    if me:
        nodes.append(_node(me, self_node=True))
    nodes.extend(_node(p) for p in (data.get("Peer") or {}).values())
    nodes.sort(key=lambda n: (not n["online"], not n["self"], (n["host"] or "").lower()))
    online = sum(1 for n in nodes if n["online"])
    with _lock:
        cycle_at = _state["cycle_at"] or None
    present = {(n["host"] or "").lower() for n in nodes}
    present |= {(n["hostname"] or "").lower() for n in nodes}
    expected = [name for name in EXPECTED if name not in present]
    return {
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "cycle_at": (
            datetime.fromtimestamp(cycle_at, timezone.utc).isoformat(timespec="seconds")
            if cycle_at
            else None
        ),
        "cycle_age": round(time.time() - cycle_at, 1) if cycle_at else None,
        "ping_interval": PING_INTERVAL,
        "notifications": bool(_gotify_token()),
        "expected": expected,
        "tailnet": (data.get("CurrentTailnet") or {}).get("Name"),
        "magic_dns": data.get("MagicDNSSuffix"),
        "version": data.get("Version"),
        "backend_state": data.get("BackendState"),
        "counts": {
            "total": len(nodes),
            "online": online,
            "offline": len(nodes) - online,
            "direct": sum(1 for n in nodes if n["online"] and n["direct"]),
        },
        "tunnels": _tunnels(),
        "nodes": nodes,
    }


PAGE = """<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>mesh · tailnet</title>
<style>
  :root {
    --base:#1e1e2e; --mantle:#181825; --crust:#11111b; --surface0:#313244;
    --surface1:#45475a; --text:#cdd6f4; --subtext:#a6adc8; --overlay:#6c7086;
    --lavender:#b4befe; --mauve:#cba6f7; --green:#a6e3a1; --yellow:#f9e2af;
    --red:#f38ba8; --blue:#89b4fa; --teal:#94e2d5;
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--base); color:var(--text);
    font:14px/1.45 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    padding:28px 20px 48px; }
  .wrap { max-width:1080px; margin:0 auto; }
  header { display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; margin-bottom:6px; }
  h1 { font-size:22px; font-weight:600; margin:0; letter-spacing:-.01em; }
  h1 span { color:var(--lavender); }
  .sub { color:var(--overlay); font-size:12.5px; }
  .stats { display:flex; gap:8px; flex-wrap:wrap; margin:18px 0 22px; }
  .chip { background:var(--mantle); border:1px solid var(--surface0); border-radius:999px;
    padding:5px 12px; font-size:12.5px; color:var(--subtext); display:flex; gap:7px; align-items:center; }
  .chip b { color:var(--text); font-weight:600; }
  .dot { width:7px; height:7px; border-radius:50%; display:inline-block; }
  .on { background:var(--green); box-shadow:0 0 0 3px rgba(166,227,161,.14); }
  .off { background:var(--red); box-shadow:0 0 0 3px rgba(243,139,168,.12); }
  .warn { background:var(--yellow); box-shadow:0 0 0 3px rgba(249,226,175,.12); }
  .grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill,minmax(320px,1fr)); }
  .card { background:var(--mantle); border:1px solid var(--surface0); border-radius:14px;
    padding:14px 16px; transition:border-color .15s, opacity .2s; }
  .card:hover { border-color:var(--surface1); }
  .card.offline { opacity:.62; }
  .card.self { border-color:rgba(180,190,254,.45); }
  .top { display:flex; align-items:center; gap:9px; }
  .host { font-size:15.5px; font-weight:600; }
  .badge { margin-left:auto; font-size:10.5px; text-transform:uppercase; letter-spacing:.06em;
    color:var(--overlay); border:1px solid var(--surface0); border-radius:999px; padding:2px 8px; }
  .ip { font-family:ui-monospace,SFMono-Regular,"JetBrains Mono",monospace; font-size:13px;
    color:var(--lavender); cursor:pointer; user-select:all; }
  .ip:hover { text-decoration:underline; }
  .rows { margin-top:11px; display:grid; gap:5px; }
  .row { display:flex; gap:8px; font-size:12.5px; align-items:baseline; }
  .k { color:var(--overlay); min-width:82px; }
  .v { color:var(--subtext); }
  .v.mono { font-family:ui-monospace,SFMono-Regular,monospace; font-size:12px; }
  .ok { color:var(--green); } .relay { color:var(--yellow); } .bad { color:var(--red); }
  .fresh { color:var(--subtext); } .stale { color:var(--yellow); }
  .dns { margin-top:10px; font-size:11px; color:var(--overlay);
    font-family:ui-monospace,SFMono-Regular,monospace; overflow-wrap:anywhere; }
  footer { margin-top:26px; color:var(--overlay); font-size:11.5px; display:flex;
    justify-content:space-between; gap:10px; flex-wrap:wrap; }
  .empty { color:var(--overlay); font-size:13px; }
  /* "tunnels" section: backup access, reused from tunnel-health */
  .tuns { margin-top:34px; }
  .tunhead { display:flex; align-items:baseline; justify-content:space-between;
    gap:12px; flex-wrap:wrap; margin-bottom:10px; }
  h2 { font-size:15px; font-weight:600; margin:0; letter-spacing:-.01em; }
  h2 span { color:var(--lavender); }
  .tunhead a { color:var(--overlay); font-size:11.5px; text-decoration:none; }
  .tunhead a:hover { color:var(--lavender); text-decoration:underline; }
  .alert { display:none; margin-bottom:10px; padding:9px 13px; border-radius:10px;
    font-size:12.5px; background:rgba(249,226,175,.1); color:var(--yellow);
    border:1px solid rgba(249,226,175,.3); }
  .alert.on { display:block; }
  .twrap { overflow-x:auto; border:1px solid var(--surface0); border-radius:14px;
    background:var(--mantle); }
  .twrap table { width:100%; border-collapse:collapse; min-width:780px; }
  .twrap th { text-align:left; font-size:10.5px; font-weight:600; letter-spacing:.08em;
    text-transform:uppercase; color:var(--overlay); padding:11px 14px;
    border-bottom:1px solid var(--surface0); }
  .twrap td { padding:11px 14px; border-bottom:1px solid rgba(49,50,68,.55);
    font-size:12.5px; vertical-align:top; }
  .twrap tbody tr:last-child td { border-bottom:0; }
  .twrap tbody tr:hover td { background:rgba(49,50,68,.3); }
  .talias { font-family:ui-monospace,SFMono-Regular,"JetBrains Mono",monospace;
    font-weight:600; color:var(--lavender); white-space:nowrap; }
  .ttarget { font-family:ui-monospace,SFMono-Regular,"JetBrains Mono",monospace;
    font-size:12px; color:var(--subtext); white-space:nowrap; }
  .tpurpose { color:var(--subtext); max-width:330px; }
  .tnum { text-align:right; white-space:nowrap;
    font-family:ui-monospace,SFMono-Regular,"JetBrains Mono",monospace;
    font-size:12px; color:var(--subtext); }
  .pill { display:inline-block; padding:2px 9px; border-radius:999px;
    font-size:11.5px; font-weight:600; white-space:nowrap; }
  .pill.up { background:rgba(166,227,161,.14); color:var(--green); }
  .pill.down { background:rgba(243,139,168,.14); color:var(--red); }
  .pill.unknown { background:rgba(249,226,175,.14); color:var(--yellow); }
  .tdetail { color:var(--overlay); font-size:11px; margin-top:3px; max-width:230px;
    white-space:normal; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>mesh <span>·</span> tailnet</h1>
    <div class="sub" id="net"></div>
  </header>
  <div class="stats" id="stats"></div>
  <div class="grid" id="grid"><div class="empty">loading...</div></div>
  <section class="tuns">
    <div class="tunhead">
      <h2>tunnels <span>·</span> backup access</h2>
      <div class="sub" id="tunmeta"></div>
    </div>
    <div class="alert" id="tunalert"></div>
    <div class="twrap">
      <table>
        <thead><tr>
          <th>alias</th><th>target</th><th>role</th><th>state</th>
          <th class="tnum">latency</th><th class="tnum">since</th>
        </tr></thead>
        <tbody id="tunrows"><tr><td colspan="6" class="empty">loading...</td></tr></tbody>
      </table>
    </div>
  </section>
  <footer>
    <div id="gen"></div>
    <div id="cyc"></div>
  </footer>
</div>
<script>
const fmtBytes = n => {
  if (!n) return "0 B";
  const u = ["B","kB","MB","GB","TB"]; let i = 0;
  while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
  return n.toFixed(n < 10 && i > 0 ? 1 : 0) + " " + u[i];
};
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

// readable age: "3 s", "2 min 10 s", "1 h 04"
function ago(ts) {
  if (!ts) return null;
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 90) return Math.round(s) + " s";
  if (s < 5400) { const m = Math.floor(s / 60); return m + " min " + String(Math.round(s % 60)).padStart(2, "0") + " s"; }
  const h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60);
  return h + " h " + String(m).padStart(2, "0");
}
const clock = ts => ts ? new Date(ts * 1000).toLocaleTimeString("fr-FR") : "—";
const ageClass = (ts, maxAge) => (ts && Date.now() / 1000 - ts <= maxAge) ? "fresh" : "stale";

function card(n, interval) {
  const dot = `<span class="dot ${n.online ? "on" : "off"}"></span>`;
  const ping = n.self
    ? `<span style="color:var(--overlay)">—</span>`
    : (n.ping && n.ping.ok
      ? `<span class="${n.ping.direct ? "ok" : "relay"}">${Math.round(n.ping.ms)} ms</span>` +
        `<span style="color:var(--overlay)"> · ${esc(n.ping.via || "")}</span>`
      : `<span class="bad">${n.online ? "no response" : "—"}</span>`);
  const pathCls = !n.online ? "bad" : (n.direct ? "ok" : "relay");
  const check = n.last_check
    ? `<span class="${ageClass(n.last_check, interval * 3 + 15)}">${ago(n.last_check)} ago</span>`
    : `<span style="color:var(--overlay)">never measured</span>`;
  const seen = n.online
    ? `<span class="ok">now</span>`
    : (n.last_online
      ? `<span class="stale">${clock(n.last_online)} · ${ago(n.last_online)} ago</span>`
      : `<span style="color:var(--overlay)">—</span>`);
  return `<div class="card ${n.online ? "" : "offline"} ${n.self ? "self" : ""}">
    <div class="top">${dot}<span class="host">${esc(n.host)}</span>
      <span class="badge">${n.self ? "this node" : esc(n.os)}</span></div>
    <div style="margin-top:6px" class="ip" data-ip="${esc(n.ip4 || "")}">${esc(n.ip4 || "—")}</div>
    <div class="rows">
      <div class="row"><span class="k">path</span><span class="v mono ${pathCls}">${esc(n.path)}</span></div>
      <div class="row"><span class="k">latency</span><span class="v mono">${ping}</span></div>
      <div class="row"><span class="k">last check</span><span class="v mono">${check}</span></div>
      <div class="row"><span class="k">seen online</span><span class="v mono">${seen}</span></div>
      <div class="row"><span class="k">traffic</span><span class="v mono">${n.self ? "—" : "↓ " + fmtBytes(n.rx) + " · ↑ " + fmtBytes(n.tx)}</span></div>
      ${n.hostname && n.hostname !== n.host
        ? `<div class="row"><span class="k">hostname</span><span class="v mono">${esc(n.hostname)}</span></div>` : ""}
    </div>
    <div class="dns">${esc(n.dns)}</div>
  </div>`;
}

const TUN_LABEL = {up: "online", down: "offline", unknown: "unknown"};

function tunRow(r) {
  const status = TUN_LABEL[r.status] ? r.status : "unknown";
  const lat = (r.latency_ms === null || r.latency_ms === undefined)
    ? "—" : Math.round(r.latency_ms) + " ms";
  return `<tr>
    <td class="talias">${esc(r.alias)}</td>
    <td class="ttarget">${esc(r.target || "—")}</td>
    <td class="tpurpose">${esc(r.purpose || "")}</td>
    <td><span class="pill ${status}">${TUN_LABEL[status]}</span>` +
    (r.detail ? `<div class="tdetail">${esc(r.detail)}</div>` : "") + `</td>
    <td class="tnum">${lat}</td>
    <td class="tnum">${r.since ? ago(r.since) : "—"}</td>
  </tr>`;
}

// "tunnels" section: snapshot of the tunnel-health probe (60 s), reread by the
// server. A silent or absent probe must be seen, not guessed.
function renderTunnels(t) {
  const rows = document.getElementById("tunrows");
  const meta = document.getElementById("tunmeta");
  const alert = document.getElementById("tunalert");
  if (!t || !t.available) {
    rows.innerHTML = `<tr><td colspan="6" class="empty">no snapshot: the tunnel-health probe has not run yet</td></tr>`;
    meta.textContent = "tunnel-health-probe probe · every 60 s";
    alert.className = "alert";
    return;
  }
  rows.innerHTML = t.rows.map(tunRow).join("") ||
    `<tr><td colspan="6" class="empty">no tunnel declared</td></tr>`;
  const bad = t.counts.down + t.counts.unknown;
  meta.innerHTML = (bad
      ? `<span class="bad">${bad} of ${t.counts.total} offline or unknown</span>`
      : `<span class="ok">${t.counts.total} of ${t.counts.total} online</span>`) +
    ` · checked ${ago(t.checked_at)} ago · ` +
    `<a href="https://tunnel.marcpartensky.com">tunnel-health page</a>`;
  const msg = t.stale
    ? "Probe silent for more than 3 minutes: the states below are stale."
    : (t.rack_error ? "VPS unreachable from tower: the reverse tunnels are unknown (" + t.rack_error + ")." : "");
  alert.textContent = msg;
  alert.className = "alert" + (msg ? " on" : "");
}

async function refresh() {
  let d;
  try { d = await (await fetch("/api/nodes", {cache:"no-store"})).json(); }
  catch (e) { document.getElementById("gen").textContent = "offline: " + e; return; }
  const c = d.counts;
  const t = d.tunnels || {available: false};
  const tunnelChip = !t.available
    ? `<div class="chip"><span class="dot warn"></span>tunnels: probe absent</div>`
    : `<div class="chip"><span class="dot ${t.counts.up === t.counts.total ? "on" : "off"}"></span>` +
      `<b>${t.counts.up}/${t.counts.total}</b> tunnels</div>`;
  document.getElementById("net").textContent =
    `${d.tailnet || "?"} · MagicDNS ${d.magic_dns || "?"} · tailscale ${d.version || "?"}`;
  document.getElementById("stats").innerHTML =
    `<div class="chip"><span class="dot on"></span><b>${c.online}</b> online</div>` +
    `<div class="chip"><span class="dot off"></span><b>${c.offline}</b> offline</div>` +
    `<div class="chip"><b>${c.direct}</b> direct</div>` +
    `<div class="chip"><b>${c.total}</b> nodes</div>` +
    tunnelChip +
    `<div class="chip"><span class="dot ${d.notifications ? "on" : "warn"}"></span>` +
      `${d.notifications ? "Gotify notifications active" : "Gotify: missing token"}</div>` +
    (d.expected && d.expected.length
      ? `<div class="chip"><span class="dot warn"></span>pending: ${d.expected.map(esc).join(", ")}</div>`
      : "");
  document.getElementById("grid").innerHTML = d.nodes.map(n => card(n, d.ping_interval)).join("");
  renderTunnels(t);
  document.getElementById("gen").textContent =
    "page updated " + new Date(d.generated).toLocaleTimeString("fr-FR") +
    " · " + (d.backend_state || "");
  document.getElementById("cyc").textContent =
    (d.cycle_age === null
      ? "no measurement cycle yet"
      : "last measurement cycle: " + ago(Date.now() / 1000 - d.cycle_age) + " ago") +
    " · ping every " + Math.round(d.ping_interval) + " s · source tailscale status --json";
}
document.addEventListener("click", e => {
  const el = e.target.closest("[data-ip]");
  if (el && el.dataset.ip) navigator.clipboard?.writeText(el.dataset.ip);
});
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "mesh-dashboard"

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/nodes":
            self._send(200, json.dumps(snapshot()).encode(), "application/json; charset=utf-8")
        elif path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, b"not found\n", "text/plain; charset=utf-8")

    def log_message(self, fmt: str, *args) -> None:  # quiet systemd journal
        return


def main() -> None:
    _load_history()
    threading.Thread(target=_pinger, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"mesh-dashboard on http://{HOST}:{PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
