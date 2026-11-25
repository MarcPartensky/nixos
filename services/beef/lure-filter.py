#!/usr/bin/env python3
"""Public filter for the BeEF lure.

The Cloudflare tunnel hits this relay (127.0.0.1:BEEF_FILTER_PORT) which relays to
BeEF (127.0.0.1:BEEF_BACKEND_PORT) while refusing anything that is not public:
operator console (/ui) and admin REST API (/api/).

Why a path filter and not BeEF's IP restrictions: an outbound tunnel
arrives from loopback, so permitted_hooking_subnet and
permitted_ui_subnet cannot tell the public from the local. The only
reliable boundary is here.

The hook only uses GET /hook.js?BEEFHOOK=... (XHR polling, WebSocket
disabled): no WebSocket upgrade to handle, an HTTP relay is enough.
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

# Prefixes never served to the public (operator console and admin API).
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

    def log_message(self, format, *args):  # noqa: A002 - base class signature
        # silence stderr, we log ourselves into BEEF_FILTER_LOG
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
        print(f"beef-lure-filter: cannot bind on {LISTEN_PORT}: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"lure filter on 127.0.0.1:{LISTEN_PORT} -> BeEF {BACKEND_HOST}:{BACKEND_PORT}", flush=True)
    server.serve_forever()
