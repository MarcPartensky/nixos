#!/usr/bin/env python3
"""Health of the SSH aliases and reverse tunnels of the homelab.

Two modes, one file:

  probe   measure every alias, persist a snapshot, render the page
  web     serve that page on a loopback port (newt/Pangolin does TLS and SSO)

Every check is a real SSH banner read through the path the alias uses, so a
green row means "you can ssh there right now", not "the port is bound":

  lan     direct TCP + banner from tower (home LAN, no mesh involved)
  local   TCP + banner on tower's loopback (wstunnel client entry points)
  rack    one ssh to the VPS, then TCP + banner on its loopback, where every
          reverse tunnel lands (the VPS is the only host that can see them)

stdlib only.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import socket
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE_DIR = Path(os.environ.get("TUNNEL_HEALTH_DIR", "/var/lib/tunnel-health"))
ENDPOINTS_FILE = Path(os.environ.get("TUNNEL_HEALTH_ENDPOINTS", "/etc/tunnel-health/endpoints.json"))
RACK_HOST = os.environ.get("TUNNEL_HEALTH_RACK_HOST", "root@marcpartensky.com")
SSH_KEY = os.environ.get("TUNNEL_HEALTH_SSH_KEY", "/var/lib/hermes/.ssh/id_ed25519")
SSH_KNOWN_HOSTS = os.environ.get("TUNNEL_HEALTH_KNOWN_HOSTS", "/var/lib/hermes/.ssh/known_hosts")
PORT = int(os.environ.get("TUNNEL_HEALTH_PORT", "9141"))
BANNER_TIMEOUT = 3.0
RACK_SSH_TIMEOUT = 20

# Runs on the VPS with bash -s: prints "<port> <state> <ms>" per port.
# /dev/tcp cannot hang on a closed loopback port (immediate ECONNREFUSED); the
# read timeout covers a forward that accepts and then never answers.
RACK_SCRIPT = r"""
while [ "$#" -gt 0 ]; do
  port=$1
  shift
  t0=$(date +%s%3N)
  if ! exec {fd}<>/dev/tcp/127.0.0.1/"$port" 2>/dev/null; then
    echo "$port closed 0"
    continue
  fi
  if IFS= read -r -t 3 line <&"$fd"; then
    t1=$(date +%s%3N)
    case "$line" in
      SSH-*) echo "$port up $((t1 - t0))" ;;
      *)     echo "$port other $((t1 - t0))" ;;
    esac
  else
    echo "$port nobanner $(( $(date +%s%3N) - t0 ))"
  fi
  exec {fd}>&-
done
"""

REASONS = {
    "closed": "port fermé sur le VPS (tunnel absent)",
    "nobanner": "port ouvert, aucune bannière SSH",
    "other": "réponse inattendue (pas SSH)",
}


# ---------------------------------------------------------------------------
# measurements
# ---------------------------------------------------------------------------

def probe_tcp(host: str, port: int) -> dict:
    """TCP connect + SSH banner read; returns {status, latency_ms, detail}."""
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=BANNER_TIMEOUT) as sock:
            sock.settimeout(BANNER_TIMEOUT)
            data = b""
            while len(data) < 64 and b"\n" not in data:
                chunk = sock.recv(64 - len(data))
                if not chunk:
                    break
                data += chunk
    except ConnectionRefusedError:
        return {"status": "down", "latency_ms": None, "detail": "connexion refusée"}
    except socket.timeout:
        return {"status": "down", "latency_ms": None, "detail": "timeout"}
    except OSError as exc:
        return {"status": "down", "latency_ms": None, "detail": str(exc)}
    latency = int((time.monotonic() - t0) * 1000)
    if data.startswith(b"SSH-"):
        return {"status": "up", "latency_ms": latency, "detail": ""}
    return {"status": "down", "latency_ms": latency, "detail": "pas de bannière SSH"}


def probe_rack(ports: list[int]) -> tuple[dict, str]:
    """Probe loopback ports on the VPS in a single ssh call.

    Returns ({port: result}, error) where error is non-empty when the ssh to the
    VPS itself failed (then every rack row is "unknown", not "down").
    """
    cmd = [
        "ssh", "-T",
        "-i", SSH_KEY,
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=" + SSH_KNOWN_HOSTS,
        "-o", "LogLevel=ERROR",
        RACK_HOST, "bash", "-s", "--", *[str(p) for p in ports],
    ]
    try:
        proc = subprocess.run(
            cmd, input=RACK_SCRIPT, capture_output=True, text=True,
            timeout=RACK_SSH_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {}, "ssh vers le VPS : timeout"
    except OSError as exc:
        return {}, f"ssh vers le VPS : {exc}"
    if proc.returncode != 0:
        err = (proc.stderr or "").strip().splitlines()
        return {}, "ssh vers le VPS : " + (err[-1] if err else f"code {proc.returncode}")
    results: dict[int, dict] = {}
    for line in (proc.stdout or "").splitlines():
        parts = line.split()
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        port, state, ms = int(parts[0]), parts[1], parts[2]
        if state == "up":
            results[port] = {"status": "up", "latency_ms": int(ms), "detail": ""}
        else:
            results[port] = {
                "status": "down",
                "latency_ms": None,
                "detail": REASONS.get(state, f"état {state}"),
            }
    missing = [p for p in ports if p not in results]
    if missing:
        return results, "réponse incomplète du VPS (ports " + ", ".join(map(str, missing)) + ")"
    return results, ""


def measure(endpoints: list[dict]) -> tuple[dict, str]:
    rack_ports = [ep["port"] for ep in endpoints if ep["via"] == "rack"]
    rack, rack_error = probe_rack(sorted(set(rack_ports))) if rack_ports else ({}, "")
    out: dict[str, dict] = {}
    for ep in endpoints:
        if ep["via"] == "rack":
            if rack_error and ep["port"] not in rack:
                out[ep["alias"]] = {"status": "unknown", "latency_ms": None, "detail": rack_error}
            else:
                out[ep["alias"]] = rack[ep["port"]]
        elif ep["via"] == "local":
            out[ep["alias"]] = probe_tcp("127.0.0.1", ep["port"])
        else:
            out[ep["alias"]] = probe_tcp(ep["host"], ep["port"])
    return out, rack_error


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

def load_state() -> dict:
    try:
        return json.loads((STATE_DIR / "status.json").read_text())
    except (OSError, ValueError):
        return {"aliases": {}}


def save_state(state: dict) -> None:
    (STATE_DIR / "status.json").write_text(json.dumps(state, indent=1, sort_keys=True))


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

def ago(ts: float | None, now: float) -> str:
    if not ts:
        return "jamais"
    secs = max(0, int(now - ts))
    if secs < 90:
        return f"il y a {secs} s"
    if secs < 5400:
        return f"il y a {secs // 60} min"
    if secs < 172800:
        return f"il y a {secs // 3600} h"
    return f"il y a {secs // 86400} j"


def duration(ts: float | None, now: float) -> str:
    if not ts:
        return "?"
    secs = max(0, int(now - ts))
    if secs < 90:
        return f"{secs} s"
    if secs < 5400:
        return f"{secs // 60} min"
    if secs < 172800:
        return f"{secs // 3600} h {(secs % 3600) // 60:02d}"
    return f"{secs // 86400} j"


LABELS = {
    "up": ("en ligne", "up"),
    "down": ("hors ligne", "down"),
    "unknown": ("indéterminé", "unknown"),
}


def render(endpoints: list[dict], state: dict) -> str:
    now = time.time()
    checked = state.get("checked_at")
    rows = []
    for ep in endpoints:
        entry = state.get("aliases", {}).get(ep["alias"], {})
        status = entry.get("status", "unknown")
        label, css = LABELS.get(status, LABELS["unknown"])
        latency = entry.get("latency_ms")
        lat = f"{latency} ms" if latency is not None else "—"
        detail = entry.get("detail") or ""
        sub = f'<div class="detail">{html.escape(detail)}</div>' if detail else ""
        since = entry.get("since")
        since_txt = duration(since, now) if since else "—"
        rows.append(f"""
      <tr class="{css}">
        <td class="alias">{html.escape(ep['alias'])}</td>
        <td class="target">{html.escape(ep['target'])}</td>
        <td class="purpose">{html.escape(ep['purpose'])}</td>
        <td class="state"><span class="pill {css}">{label}</span>{sub}</td>
        <td class="num">{lat}</td>
        <td class="num since" title="{html.escape(ep.get('via',''))}">{since_txt}</td>
      </tr>""")
    checked_iso = datetime.fromtimestamp(checked, tz=timezone.utc).isoformat() if checked else ""
    checked_local = (
        datetime.fromtimestamp(checked).strftime("%d/%m %H:%M:%S") if checked else "jamais"
    )
    return f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>Santé des tunnels</title>
<style>
  :root {{
    --bg: #1e1e2e; --card: #181825; --surface: #313244; --surface2: #45475a;
    --text: #cdd6f4; --sub: #a6adc8; --overlay: #6c7086;
    --green: #a6e3a1; --red: #f38ba8; --yellow: #f9e2af; --lav: #b4befe;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--text);
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }}
  main {{ max-width: 1020px; margin: 0 auto; padding: 32px 20px 48px; }}
  header {{ display: flex; flex-wrap: wrap; align-items: baseline; gap: 12px;
    justify-content: space-between; margin-bottom: 4px; }}
  h1 {{ font-size: 22px; font-weight: 600; margin: 0; letter-spacing: .2px; }}
  h1 span {{ color: var(--lav); }}
  .sub {{ color: var(--sub); margin: 2px 0 22px; font-size: 13px; }}
  .sub b {{ color: var(--text); font-weight: 500; }}
  #stale {{ display: none; margin: 0 0 16px; padding: 10px 14px; border-radius: 10px;
    background: rgba(243,139,168,.12); color: var(--red); font-size: 13px;
    border: 1px solid rgba(243,139,168,.35); }}
  #stale.on {{ display: block; }}
  .wrap {{ overflow-x: auto; border-radius: 14px; border: 1px solid var(--surface);
    background: var(--card); }}
  table {{ width: 100%; border-collapse: collapse; min-width: 780px; }}
  th {{ text-align: left; font-size: 11px; font-weight: 600; letter-spacing: .9px;
    text-transform: uppercase; color: var(--overlay); padding: 12px 16px;
    border-bottom: 1px solid var(--surface); }}
  td {{ padding: 13px 16px; border-bottom: 1px solid rgba(49,50,68,.6); vertical-align: top; }}
  tr:last-child td {{ border-bottom: 0; }}
  tr:hover td {{ background: rgba(49,50,68,.35); }}
  .alias {{ font-family: ui-monospace, "SF Mono", "JetBrains Mono", monospace;
    font-weight: 600; color: var(--lav); white-space: nowrap; }}
  .target {{ font-family: ui-monospace, "SF Mono", "JetBrains Mono", monospace;
    font-size: 12.5px; color: var(--sub); white-space: nowrap; }}
  .purpose {{ color: var(--sub); font-size: 13px; max-width: 340px; }}
  .state {{ white-space: nowrap; }}
  .pill {{ display: inline-block; padding: 3px 10px; border-radius: 999px;
    font-size: 12px; font-weight: 600; }}
  .pill.up {{ background: rgba(166,227,161,.14); color: var(--green); }}
  .pill.down {{ background: rgba(243,139,168,.14); color: var(--red); }}
  .pill.unknown {{ background: rgba(249,226,175,.14); color: var(--yellow); }}
  .detail {{ color: var(--overlay); font-size: 11.5px; margin-top: 4px; max-width: 230px; }}
  .num {{ font-family: ui-monospace, "SF Mono", "JetBrains Mono", monospace;
    font-size: 12.5px; color: var(--sub); white-space: nowrap; text-align: right; }}
  .since {{ color: var(--text); }}
  footer {{ color: var(--overlay); font-size: 12px; margin-top: 18px; line-height: 1.7; }}
  footer code {{ color: var(--sub); }}
  a {{ color: var(--lav); text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
</style>
</head>
<body>
<main>
  <header>
    <h1>Santé des <span>tunnels</span></h1>
    <div class="sub" style="margin:0">vérifié {checked_local} · rafraîchi toutes les 15 s</div>
  </header>
  <p class="sub">Chaque ligne est une lecture de bannière SSH par le chemin réel de
    l'alias : LAN direct, loopback de tower, ou loopback du VPS pour les tunnels inverses.
    Vert = <b>tu peux te connecter maintenant</b>.</p>
  <div id="stale">La sonde n'a pas tourné depuis plus de 3 minutes : les données affichées sont périmées.</div>
  <div class="wrap">
  <table>
    <thead><tr>
      <th>Alias</th><th>Cible</th><th>Rôle</th><th>État</th><th class="num">Latence</th><th class="num">Depuis</th>
    </tr></thead>
    <tbody>{"".join(rows)}
    </tbody>
  </table>
  </div>
  <footer>
    Sonde : unité <code>tunnel-health-probe</code> sur tower, toutes les 60 s, un seul ssh vers
    le VPS pour les quatre tunnels inverses. <code>unknown</code> = le VPS lui-même est
    injoignable, donc le tunnel n'est pas mesurable (ce n'est pas une preuve qu'il est tombé).<br>
    Le mesh (tower, deck, laptop, mac, phone, vps) a sa propre page :
    <a href="https://mesh.marcpartensky.com">mesh.marcpartensky.com</a>.
  </footer>
</main>
<script>
  const checked = {json.dumps(checked_iso)};
  if (checked && Date.now() - Date.parse(checked) > 180000) {{
    document.getElementById('stale').classList.add('on');
  }}
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

def load_endpoints() -> list[dict]:
    return json.loads(ENDPOINTS_FILE.read_text())


def cmd_probe() -> int:
    endpoints = load_endpoints()
    state = load_state()
    started = time.time()
    results, rack_error = measure(endpoints)
    now = time.time()
    aliases = {}
    for ep in endpoints:
        res = results.get(ep["alias"], {"status": "unknown", "latency_ms": None, "detail": ""})
        prev = state.get("aliases", {}).get(ep["alias"], {})
        status = res["status"]
        same = prev.get("status") == status
        entry = {
            "status": status,
            "latency_ms": res["latency_ms"],
            "detail": res["detail"],
            "checked_at": now,
            "last_ok": now if status == "up" else prev.get("last_ok"),
            # "since" = start of the current streak for this status.
            "since": prev.get("since") if same and prev.get("since") else now,
        }
        aliases[ep["alias"]] = entry
    new_state = {
        "checked_at": now,
        "duration_ms": int((now - started) * 1000),
        "rack_error": rack_error,
        # Metadonnees des endpoints : le dashboard du tailnet relit ce fichier
        # seul pour sa section « tunnels », sans redeclarer les alias.
        "endpoints": [
            {k: ep.get(k) for k in ("alias", "target", "purpose", "via", "user")}
            for ep in endpoints
        ],
        "aliases": aliases,
    }
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    save_state(new_state)
    (STATE_DIR / "index.html").write_text(render(endpoints, new_state))
    (STATE_DIR / "healthz").write_text("ok\n")
    down = [a for a, e in aliases.items() if e["status"] != "up"]
    print(f"checked {len(endpoints)} aliases in {new_state['duration_ms']} ms; "
          f"not up: {', '.join(down) if down else 'none'}")
    return 0


class Handler(BaseHTTPRequestHandler):
    server_version = "tunnel-health"
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        path = self.path.split("?", 1)[0]
        try:
            if path in ("/", "/index.html"):
                self._send(200, (STATE_DIR / "index.html").read_bytes(), "text/html; charset=utf-8")
            elif path == "/status.json":
                self._send(200, (STATE_DIR / "status.json").read_bytes(), "application/json")
            elif path == "/healthz":
                self._send(200, b"ok\n", "text/plain; charset=utf-8")
            else:
                self._send(404, b"not found\n", "text/plain; charset=utf-8")
        except OSError:
            self._send(503, b"no snapshot yet\n", "text/plain; charset=utf-8")

    def log_message(self, format: str, *args) -> None:  # noqa: A002 (http.server API)
        print(f"{self.address_string()} {format % args}", flush=True)


def cmd_web(host: str, port: int) -> int:
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"serving {STATE_DIR} on http://{host}:{port}", flush=True)
    server.serve_forever()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("probe")
    web = sub.add_parser("web")
    web.add_argument("--host", default="127.0.0.1")
    web.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()
    if args.mode == "probe":
        return cmd_probe()
    return cmd_web(args.host, args.port)


if __name__ == "__main__":
    raise SystemExit(main())
