#!/usr/bin/env python3
"""Dashboard des nœuds du tailnet (headscale) vus depuis tower.

Source unique : `tailscale status --json` (client du mesh, socket
/var/run/tailscale/tailscaled.sock, lisible par l'utilisateur du service) et
`tailscale ping` pour mesurer le chemin réel de chaque pair en ligne.

Aucune dépendance : stdlib seulement. Sert une page HTML (polling /api/nodes)
et le JSON brut. La latence est mesurée en tâche de fond, jamais dans une
requête HTTP, pour que la page reste instantanée même si un pair ne répond pas.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("MESH_DASHBOARD_HOST", "0.0.0.0")
PORT = int(os.environ.get("MESH_DASHBOARD_PORT", "9130"))

STATUS_TTL = 3.0        # cache de `tailscale status`
PING_INTERVAL = 20.0    # période du mesureur de latence
PING_TIMEOUT = "2s"

_lock = threading.Lock()
_state: dict = {"status": None, "status_at": 0.0, "pings": {}, "pings_at": 0.0}


def _run(cmd: list[str], timeout: float = 10.0) -> str:
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout, check=False
    ).stdout


def _status() -> dict:
    """`tailscale status --json`, avec un cache court (les pairs changent peu)."""
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
    """Latence + chemin (`via 192.168.1.31:41641` ou `via DERP(vps)`).

    On pingue l'IP du mesh, jamais le nom : le HostName d'un nœud peut différer
    de son nom MagicDNS (le laptop s'appelle `nixos` en local mais `laptop` sur
    le contrôleur), et `tailscale ping nixos` ne résout alors rien.
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


def _ping_all() -> None:
    data = _status()
    peers = list((data.get("Peer") or {}).values())
    pings: dict[str, dict] = {}
    for peer in peers:
        # On ne mesure que ce qui est joignable : un pair hors ligne ne fera
        # que brûler le timeout.
        if not peer.get("Online"):
            continue
        ips = peer.get("TailscaleIPs") or []
        if not ips:
            continue
        pings[peer.get("ID", ips[0])] = _ping(ips[0])
    with _lock:
        _state["pings"] = pings
        _state["pings_at"] = time.time()


def _pinger() -> None:
    while True:
        try:
            _ping_all()
        except Exception:  # un pair qui disparaît ne doit pas tuer la boucle
            pass
        time.sleep(PING_INTERVAL)


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
        path = "hors ligne"
    elif cur_addr:
        path = f"direct {cur_addr}"
    elif relay:
        path = f"relais DERP {relay}"
    else:
        path = "inconnu"
    key = peer.get("ID") or ip4 or peer.get("HostName")
    with _lock:
        ping = dict(_state["pings"].get(key) or {})
    dns = (peer.get("DNSName") or "").rstrip(".")
    # Le contrôleur renomme parfois un nœud (laptop) sans que le HostName local
    # suive (nixos) : le nom de référence est celui du MagicDNS.
    label = dns.split(".")[0] if dns else ""
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
    }


def snapshot() -> dict:
    data = _status()
    nodes = []
    me = data.get("Self")
    if me:
        nodes.append(_node(me, self_node=True))
    nodes.extend(_node(p) for p in (data.get("Peer") or {}).values())
    nodes.sort(key=lambda n: (not n["online"], not n["self"], n["host"].lower()))
    online = sum(1 for n in nodes if n["online"])
    return {
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
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
  .grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill,minmax(310px,1fr)); }
  .card { background:var(--mantle); border:1px solid var(--surface0); border-radius:14px;
    padding:14px 16px; transition:border-color .15s, opacity .2s; }
  .card:hover { border-color:var(--surface1); }
  .card.offline { opacity:.55; }
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
  .k { color:var(--overlay); min-width:66px; }
  .v { color:var(--subtext); }
  .v.mono { font-family:ui-monospace,SFMono-Regular,monospace; font-size:12px; }
  .ok { color:var(--green); } .relay { color:var(--yellow); } .bad { color:var(--red); }
  .dns { margin-top:10px; font-size:11px; color:var(--overlay);
    font-family:ui-monospace,SFMono-Regular,monospace; overflow-wrap:anywhere; }
  footer { margin-top:26px; color:var(--overlay); font-size:11.5px; display:flex;
    justify-content:space-between; gap:10px; flex-wrap:wrap; }
  .empty { color:var(--overlay); font-size:13px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>mesh <span>·</span> tailnet</h1>
    <div class="sub" id="net"></div>
  </header>
  <div class="stats" id="stats"></div>
  <div class="grid" id="grid"><div class="empty">chargement…</div></div>
  <footer>
    <div id="gen"></div>
    <div>latence mesurée toutes les 20 s · source tailscale status --json</div>
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

function card(n) {
  const dot = `<span class="dot ${n.online ? "on" : "off"}"></span>`;
  const ping = n.self
    ? `<span style="color:var(--overlay)">—</span>`
    : (n.ping && n.ping.ok
      ? `<span class="${n.ping.direct ? "ok" : "relay"}">${Math.round(n.ping.ms)} ms</span>` +
        `<span style="color:var(--overlay)"> · ${esc(n.ping.via || "")}</span>`
      : `<span class="bad">${n.online ? "pas de réponse" : "—"}</span>`);
  const pathCls = !n.online ? "bad" : (n.direct ? "ok" : "relay");
  return `<div class="card ${n.online ? "" : "offline"} ${n.self ? "self" : ""}">
    <div class="top">${dot}<span class="host">${esc(n.host)}</span>
      <span class="badge">${n.self ? "ce nœud" : esc(n.os)}</span></div>
    <div style="margin-top:6px" class="ip" data-ip="${esc(n.ip4 || "")}">${esc(n.ip4 || "—")}</div>
    <div class="rows">
      <div class="row"><span class="k">chemin</span><span class="v mono ${pathCls}">${esc(n.path)}</span></div>
      <div class="row"><span class="k">latence</span><span class="v mono">${ping}</span></div>
      <div class="row"><span class="k">trafic</span><span class="v mono">${n.self ? "—" : "↓ " + fmtBytes(n.rx) + " · ↑ " + fmtBytes(n.tx)}</span></div>
      ${n.hostname && n.hostname !== n.host
        ? `<div class="row"><span class="k">hostname</span><span class="v mono">${esc(n.hostname)}</span></div>` : ""}
    </div>
    <div class="dns">${esc(n.dns)}</div>
  </div>`;
}

async function refresh() {
  let d;
  try { d = await (await fetch("/api/nodes", {cache:"no-store"})).json(); }
  catch (e) { document.getElementById("gen").textContent = "hors ligne : " + e; return; }
  const c = d.counts;
  document.getElementById("net").textContent =
    `${d.tailnet || "?"} · MagicDNS ${d.magic_dns || "?"} · tailscale ${d.version || "?"}`;
  document.getElementById("stats").innerHTML =
    `<div class="chip"><span class="dot on"></span><b>${c.online}</b> en ligne</div>` +
    `<div class="chip"><span class="dot off"></span><b>${c.offline}</b> hors ligne</div>` +
    `<div class="chip"><b>${c.direct}</b> en direct</div>` +
    `<div class="chip"><b>${c.total}</b> nœuds</div>`;
  document.getElementById("grid").innerHTML = d.nodes.map(card).join("");
  document.getElementById("gen").textContent =
    "actualisé " + new Date(d.generated).toLocaleTimeString("fr-FR") +
    " · " + (d.backend_state || "");
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

    def log_message(self, fmt: str, *args) -> None:  # journal systemd discret
        return


def main() -> None:
    threading.Thread(target=_pinger, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"mesh-dashboard sur http://{HOST}:{PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
