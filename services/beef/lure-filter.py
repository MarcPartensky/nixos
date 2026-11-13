#!/usr/bin/env python3
"""Filtre public du leurre BeEF.

Le tunnel Cloudflare tape ce relais (127.0.0.1:BEEF_FILTER_PORT) qui relaie vers
BeEF (127.0.0.1:BEEF_BACKEND_PORT) en refusant tout ce qui n'est pas public :
console d'operateur (/ui) et API REST admin (/api/).

Pourquoi un filtre par chemin et pas les restrictions d'IP de BeEF : un tunnel
sortant arrive depuis la loopback, donc permitted_hooking_subnet et
permitted_ui_subnet ne peuvent pas distinguer le public du local. La seule
frontiere fiable est ici.

Le hook n'utilise que GET /hook.js?BEEFHOOK=... (polling XHR, WebSocket
desactive) : aucune mise a niveau WebSocket a gerer, un relais HTTP suffit.
"""

import http.client
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND_HOST = "127.0.0.1"
BACKEND_PORT = int(os.environ.get("BEEF_BACKEND_PORT", "3010"))
LISTEN_PORT = int(os.environ.get("BEEF_FILTER_PORT", "3011"))
LOG = os.environ.get("BEEF_FILTER_LOG", "/var/lib/beef/lure-filter-access.log")

# Prefixes jamais servis au public (console d'operateur et API admin).
DENY_PREFIXES = ("/ui", "/api/")

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

log_lock = threading.Lock()


def logline(msg: str) -> None:
    with log_lock:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(msg + "\n")


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "beef-lure-filter/1.0"

    def log_message(self, format, *args):  # noqa: A002 - signature de la classe de base
        # silence stderr, on journalise nous-memes dans BEEF_FILTER_LOG
        pass

    def _deny(self) -> bool:
        path = self.path.split("?", 1)[0]
        return any(path == p or path.startswith(p) for p in DENY_PREFIXES)

    def _forward(self) -> None:
        now = datetime.now(timezone.utc).strftime("%H:%M:%S")
        if self._deny():
            body = b"403 - not published\n"
            self.send_response(403)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            logline(f"{now} DENY {self.command} {self.path}")
            return

        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else None

        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Host"] = self.headers.get("Host", f"{BACKEND_HOST}:{BACKEND_PORT}")
        headers["X-Forwarded-For"] = self.client_address[0]
        headers["X-Forwarded-Proto"] = "https"

        try:
            conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=30)
            conn.request(self.command, self.path, body=payload, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except Exception as exc:
            body = f"502 - backend unreachable: {exc}\n".encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            logline(f"{now} 502  {self.command} {self.path} {exc}")
            return

        self.send_response(resp.status)
        for key, value in resp.getheaders():
            if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        logline(f"{now} {resp.status} {self.command} {self.path} {len(data)}b")
        conn.close()

    do_GET = do_POST = do_HEAD = do_OPTIONS = do_PUT = do_PATCH = _forward


if __name__ == "__main__":
    try:
        server = ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Proxy)
    except OSError as exc:
        print(f"beef-lure-filter: bind impossible sur {LISTEN_PORT}: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"filtre leurre sur 127.0.0.1:{LISTEN_PORT} -> BeEF {BACKEND_HOST}:{BACKEND_PORT}", flush=True)
    server.serve_forever()
