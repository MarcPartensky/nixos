#!/usr/bin/env python3
"""typer.marcpartensky.com : static web app + raced rooms over WebSocket.

One process, one port, Python stdlib only:

  GET /            the app (HTML/CSS/JS + word lists, served from --root)
  GET /ws          WebSocket: multiplayer race rooms (in memory, no accounts)

A race is a room code (4 characters). Anybody with the link joins as a guest:
no login, no cookie, nothing to install. Rooms live in RAM and disappear when
everybody leaves or after an hour of silence, so the server keeps no state
worth backing up.

The network path is newt/Pangolin (typer.marcpartensky.com) -> 127.0.0.1:9146.
The WebSocket upgrade crosses it untouched: Traefik and newt both proxy
HTTP/1.1 upgrades.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import random
import re
import secrets
import sys
import time
from urllib.parse import unquote, urlsplit

# ------------------------------------------------------------------ static ---

TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webmanifest": "application/manifest+json",
}

# Everything revalidates: the URLs are stable across rebuilds (the content is
# not), and the whole app is ~80 KB, so a 304 is cheaper than serving a stale
# app.js after a deploy.
CACHE = {".html": "no-cache", ".css": "no-cache", ".js": "no-cache"}

HEADERS_BASE = [
    ("X-Content-Type-Options", "nosniff"),
    ("Referrer-Policy", "no-referrer"),
    ("X-Frame-Options", "DENY"),
]

# The app only talks to its own origin; the race socket is same-origin wss.
CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; connect-src 'self'; "
    "form-action 'none'; frame-ancestors 'none'"
)

# -------------------------------------------------------------------- race ---

# Word lists a race may use. The ids match the keys of LANGS in web/app.js;
# the code lists are left out on purpose (a 30 s race over punctuation is not
# a typing drill, it is a fight with the quote key).
RACE_LANGS = ("english200", "english1000", "french200", "french1000")

AMOUNTS = (15, 30, 60, 120)

# No O/0/I/1/L: the code is read out loud or typed by hand.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LEN = 4

MAX_ROOMS = 200
MAX_PLAYERS = 12
MAX_NAME = 20
MAX_MESSAGE = 8192
IDLE_TIMEOUT = 3600  # room swept after an hour of silence
EMPTY_TIMEOUT = 120  # room swept two minutes after the last player leaves
COUNTDOWN = 3

ROOM_RE = re.compile(r"^[A-Z0-9]{%d}$" % CODE_LEN)
NAME_RE = re.compile(r"[^\w \-'.]")

DEBUG = os.environ.get("TYPER_DEBUG") == "1"


def now() -> float:
    return time.monotonic()


class Player:
    __slots__ = ("pid", "name", "ws", "wpm", "acc", "word", "chars", "ready", "done", "joined")

    def __init__(self, pid: str, name: str) -> None:
        self.pid = pid
        self.name = name
        self.ws = None
        self.wpm = 0
        self.acc = 100
        self.word = 0
        self.chars = 0
        self.ready = False
        self.done = False
        self.joined = now()

    def public(self) -> dict:
        return {
            "id": self.pid,
            "name": self.name,
            "wpm": round(self.wpm),
            "acc": round(self.acc, 1),
            "progress": self.word,
            "chars": self.chars,
            "ready": self.ready,
            "done": self.done,
        }


class Room:
    def __init__(self, code: str, lang: str, amount: int) -> None:
        self.code = code
        self.lang = lang
        self.amount = amount
        self.phase = "lobby"  # lobby | countdown | race | done
        self.players: dict[str, Player] = {}
        self.host: str | None = None
        self.words: list[str] = []
        self.starts_in = 0.0
        self.started_at = 0.0
        self.ends_at = 0.0
        self.created = now()
        self.touched = now()
        self.countdown_task: asyncio.Task | None = None

    def state(self, viewer: Player) -> dict:
        return {
            "t": "state",
            "room": self.code,
            "phase": self.phase,
            "host": self.host,
            "you": viewer.pid,
            "lang": self.lang,
            "amount": self.amount,
            "startsIn": self.starts_in,
            "endsIn": max(0.0, round(self.ends_at - now(), 1)) if self.phase == "race" else 0,
            "words": self.words if self.phase in ("race", "done") else [],
            "players": [p.public() for p in self.players.values()],
        }


def sanitize_name(raw: object, taken: set[str]) -> str:
    name = NAME_RE.sub("", str(raw or "")).strip()[:MAX_NAME]
    if not name:
        name = "guest"
    base = name
    n = 2
    while name.lower() in taken:
        name = f"{base} {n}"[:MAX_NAME]
        n += 1
    return name


def clamp(value: object, low: float, high: float, default: float = 0.0) -> float:
    try:
        v = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default
    if v != v:  # NaN
        return default
    return max(low, min(high, v))


class WSProtocolError(Exception):
    pass


class WSClosed(Exception):
    pass


async def read_http_head(reader: asyncio.StreamReader) -> tuple[str, str, dict[str, str]] | None:
    """Read the request line + headers. Returns (method, target, headers)."""
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=15)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
        return None
    try:
        text = head.decode("latin-1")
    except UnicodeDecodeError:
        return None
    lines = text.split("\r\n")
    if not lines or not lines[0]:
        return None
    parts = lines[0].split(" ")
    if len(parts) != 3:
        return None
    method, target, _version = parts
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
    return method, target, headers


async def read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    """Read one client frame (always masked) and return (opcode, payload)."""
    try:
        b1, b2 = await asyncio.wait_for(reader.readexactly(2), timeout=IDLE_TIMEOUT)
        fin = b1 & 0x80
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        length = b2 & 0x7F
        if length == 126:
            (length,) = (int.from_bytes(await reader.readexactly(2), "big"),)
        elif length == 127:
            (length,) = (int.from_bytes(await reader.readexactly(8), "big"),)
        if length > MAX_MESSAGE:
            raise WSProtocolError("frame too large")
        if not masked:
            # RFC 6455: a client frame MUST be masked.
            raise WSProtocolError("unmasked client frame")
        mask = await reader.readexactly(4)
        payload = await reader.readexactly(length)
        payload = bytes(payload[i] ^ mask[i % 4] for i in range(length))
        if not fin:
            # Fragmented message: keep reading continuation frames.
            while True:
                b1, b2 = await reader.readexactly(2)
                cont = b1 & 0x0F
                fin = b1 & 0x80
                length = b2 & 0x7F
                if length == 126:
                    (length,) = (int.from_bytes(await reader.readexactly(2), "big"),)
                elif length == 127:
                    (length,) = (int.from_bytes(await reader.readexactly(8), "big"),)
                if len(payload) + length > MAX_MESSAGE:
                    raise WSProtocolError("message too large")
                m = await reader.readexactly(4)
                part = await reader.readexactly(length)
                payload += bytes(part[i] ^ m[i % 4] for i in range(length))
                if cont not in (0x0,):
                    raise WSProtocolError("bad continuation")
                if fin:
                    break
        return opcode, payload
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError) as exc:
        raise WSClosed() from exc


def encode_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    """Server -> client frame. Servers never mask."""
    header = bytearray()
    header.append(0x80 | opcode)
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += n.to_bytes(2, "big")
    else:
        header.append(127)
        header += n.to_bytes(8, "big")
    return bytes(header) + payload


class RaceServer:
    def __init__(self, root: str) -> None:
        self.root = root
        self.rooms: dict[str, Room] = {}
        self.pools: dict[str, list[str]] = {}
        self.connections: dict[str, list[float]] = {}
        for lang in RACE_LANGS:
            path = os.path.join(root, "lang", lang)
            try:
                with open(path, encoding="utf-8") as fh:
                    words = [w for w in fh.read().split() if w]
            except OSError:
                words = []
            if len(words) >= 20:
                self.pools[lang] = words
        if not self.pools:
            raise SystemExit("no word list found under lang/")

    # ---------------------------------------------------------- connection ---

    def throttled(self, ip: str) -> bool:
        """Thirty new sockets per client per minute; rooms are capped apart."""
        stamp = now()
        bucket = [t for t in self.connections.get(ip, []) if stamp - t < 60]
        bucket.append(stamp)
        self.connections[ip] = bucket
        # Behind newt every socket comes from 127.0.0.1: the real client IP is
        # in X-Forwarded-For. Keep the map from growing without bound.
        if len(self.connections) > 5000:
            self.connections = {ip: bucket}
        return len(bucket) > 30

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername", ("?", 0))[0]
        try:
            head = await read_http_head(reader)
            if head is None:
                return
            method, target, headers = head
            forwarded = headers.get("x-forwarded-for", "").split(",")[0].strip()
            ip = forwarded or peer
            path = unquote(urlsplit(target).path)
            upgrade = headers.get("upgrade", "").lower()
            if upgrade == "websocket":
                if path != "/ws":
                    await self.reply(writer, 404, b"not found\n")
                    return
                if self.throttled(ip):
                    await self.reply(writer, 429, b"too many connections\n")
                    return
                await self.websocket(reader, writer, headers)
                return
            if method not in ("GET", "HEAD"):
                await self.reply(writer, 405, b"method not allowed\n", extra=[("Allow", "GET, HEAD")])
                return
            await self.serve_static(writer, path, head_only=(method == "HEAD"))
        except (ConnectionResetError, BrokenPipeError, WSClosed, WSProtocolError):
            pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except (ConnectionResetError, BrokenPipeError):
                pass

    async def reply(
        self,
        writer: asyncio.StreamWriter,
        status: int,
        body: bytes,
        ctype: str = "text/plain; charset=utf-8",
        extra: list[tuple[str, str]] | None = None,
        head_only: bool = False,
    ) -> None:
        reason = {200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 429: "Too Many Requests"}.get(status, "OK")
        lines = [
            f"HTTP/1.1 {status} {reason}",
            f"Content-Type: {ctype}",
            f"Content-Length: {len(body)}",
            "Connection: close",
        ]
        for k, v in HEADERS_BASE + (extra or []):
            lines.append(f"{k}: {v}")
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
        if not head_only:
            writer.write(body)
        await writer.drain()

    def resolve(self, path: str) -> str | None:
        if path.endswith("/"):
            path += "index.html"
        if "\x00" in path:
            return None
        candidate = os.path.realpath(os.path.join(self.root, path.lstrip("/")))
        if not candidate.startswith(self.root + os.sep) and candidate != self.root:
            return None
        if not os.path.isfile(candidate):
            return None
        return candidate

    async def serve_static(self, writer: asyncio.StreamWriter, path: str, head_only: bool) -> None:
        target = self.resolve(path)
        if target is None:
            await self.reply(writer, 404, b"not found\n", head_only=head_only)
            return
        try:
            with open(target, "rb") as fh:
                body = fh.read()
        except OSError:
            await self.reply(writer, 404, b"not found\n", head_only=head_only)
            return
        ext = os.path.splitext(target)[1].lower()
        extra = [("Cache-Control", CACHE.get(ext, "public, max-age=3600"))]
        if ext == ".html":
            extra.append(("Content-Security-Policy", CSP))
        await self.reply(
            writer,
            200,
            body,
            ctype=TYPES.get(ext, "application/octet-stream"),
            extra=extra,
            head_only=head_only,
        )

    # ----------------------------------------------------------- websocket ---

    async def websocket(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, headers: dict[str, str]
    ) -> None:
        key = headers.get("sec-websocket-key")
        if not key or headers.get("sec-websocket-version") != "13":
            await self.reply(writer, 400, b"bad websocket handshake\n")
            return
        accept = base64.b64encode(
            hashlib.sha1(key.encode("latin-1") + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()
        ).decode("ascii")
        writer.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("latin-1")
        )
        await writer.drain()
        await self.session(reader, writer)

    async def session(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        player: Player | None = None
        room: Room | None = None
        try:
            while True:
                opcode, payload = await read_frame(reader)
                if opcode == 0x8:  # close
                    break
                if opcode == 0x9:  # ping
                    writer.write(encode_frame(payload, 0xA))
                    await writer.drain()
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                try:
                    message = json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(message, dict):
                    continue
                kind = message.get("t")
                if kind == "join" and player is None:
                    room, player = await self.join(message, writer)
                elif player is not None and room is not None:
                    await self.command(room, player, message)
        finally:
            if room is not None and player is not None:
                self.leave(room, player)

    # -------------------------------------------------------------- rooms ---

    def new_code(self) -> str:
        while True:
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
            if code not in self.rooms:
                return code

    def make_words(self, room: Room) -> None:
        pool = self.pools.get(room.lang) or self.pools["english200"]
        count = max(200, int(room.amount * 4.5))
        out: list[str] = []
        previous = ""
        for _ in range(count):
            w = random.choice(pool)
            for _attempt in range(8):
                if w != previous:
                    break
                w = random.choice(pool)
            out.append(w)
            previous = w
        room.words = out

    async def reject(self, writer: asyncio.StreamWriter, code: str) -> None:
        try:
            writer.write(encode_frame(json.dumps({"t": "error", "error": code}).encode()))
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass

    async def join(self, message: dict, writer: asyncio.StreamWriter) -> tuple[Room | None, Player | None]:
        raw_code = str(message.get("room") or "").strip().upper()
        lang = str(message.get("lang") or "")
        if not RACE_LANGS:
            return None, None
        if lang not in self.pools:
            lang = "english200"
        try:
            amount = int(message.get("amount"))
        except (TypeError, ValueError):
            amount = 30
        if amount not in AMOUNTS:
            amount = 30

        room = self.rooms.get(raw_code) if ROOM_RE.match(raw_code) else None
        if raw_code and not ROOM_RE.match(raw_code):
            await self.reject(writer, "badcode")
            return None, None
        if raw_code and room is None:
            # An explicit code that does not exist is a typo, not a request to
            # open a room on that name: tell the guest instead of splitting the
            # group into two rooms.
            await self.reject(writer, "no_room")
            return None, None
        if room is None:
            if len(self.rooms) >= MAX_ROOMS:
                await self.reject(writer, "server_full")
                return None, None
            code = self.new_code()
            room = Room(code, lang, amount)
            self.make_words(room)
            self.rooms[code] = room

        assert room is not None
        if len(room.players) >= MAX_PLAYERS:
            await self.reject(writer, "room_full")
            return None, None
        if room.phase in ("countdown", "race", "done"):
            await self.reject(writer, "race_started")
            return None, None

        name = sanitize_name(message.get("name"), {p.name.lower() for p in room.players.values()})
        player = Player(secrets.token_hex(6), name)
        player.ws = writer
        room.players[player.pid] = player
        room.touched = now()
        if DEBUG:
            print(f"[debug] join {room.code} {name}#{player.pid[:4]} from a {len(room.players)}-player room", flush=True)
        if room.host is None:
            room.host = player.pid

        writer.write(encode_frame(json.dumps(room.state(player)).encode()))
        await writer.drain()
        await self.broadcast(room)
        return room, player

    def leave(self, room: Room, player: Player) -> None:
        room.players.pop(player.pid, None)
        room.touched = now()
        if room.host == player.pid:
            room.host = next(iter(room.players), None)
        if not room.players:
            room.touched = now()
            if room.countdown_task:
                room.countdown_task.cancel()
        else:
            asyncio.create_task(self.broadcast(room))

    async def command(self, room: Room, player: Player, message: dict) -> None:
        room.touched = now()
        kind = message.get("t")
        if DEBUG:
            print(f"[debug] {room.code} {player.name}#{player.pid[:4]} {kind} {message}", flush=True)
        if kind == "ready" and room.phase == "lobby":
            player.ready = bool(message.get("ready"))
            await self.maybe_countdown(room)
            await self.broadcast(room)
        elif kind == "progress" and room.phase in ("race", "done"):
            player.word = int(clamp(message.get("word"), 0, len(room.words), player.word))
            player.chars = int(clamp(message.get("chars"), 0, 200000, player.chars))
            player.wpm = clamp(message.get("wpm"), 0, 400, player.wpm)
            player.acc = clamp(message.get("acc"), 0, 100, player.acc)
        elif kind == "done" and room.phase == "race":
            player.done = True
            player.word = int(clamp(message.get("word"), 0, len(room.words), player.word))
            player.chars = int(clamp(message.get("chars"), 0, 200000, player.chars))
            player.wpm = clamp(message.get("wpm"), 0, 400, player.wpm)
            player.acc = clamp(message.get("acc"), 0, 100, player.acc)
            await self.broadcast(room)
        elif kind == "settings" and room.phase == "lobby" and room.host == player.pid:
            lang = str(message.get("lang") or room.lang)
            try:
                amount = int(message.get("amount"))
            except (TypeError, ValueError):
                amount = room.amount
            if lang in self.pools and amount in AMOUNTS:
                room.lang = lang
                room.amount = amount
                self.make_words(room)
                for p in room.players.values():
                    p.ready = False
                await self.broadcast(room)
        elif kind == "start" and room.phase == "lobby" and room.host == player.pid:
            await self.start_race(room)
        elif kind == "rematch" and room.phase == "done":
            # Any player can call the next round once the ranking is up.
            room.phase = "lobby"
            room.starts_in = 0
            self.make_words(room)
            for p in room.players.values():
                p.word = 0
                p.chars = 0
                p.wpm = 0
                p.acc = 100
                p.done = False
                p.ready = False
            await self.broadcast(room)
        elif kind == "leave":
            raise WSClosed()

    async def maybe_countdown(self, room: Room) -> None:
        # One player alone pressing ready must NOT start a race: the friend the
        # room was created for would be turned away with `race_started` and the
        # host would race alone without understanding why. Two players minimum;
        # the explicit `start` (host only) is there for a solo run and the probe.
        players = list(room.players.values())
        if len(players) >= 2 and all(p.ready for p in players):
            await self.start_race(room)

    async def start_race(self, room: Room) -> None:
        if room.phase != "lobby" or not room.players:
            return
        room.phase = "countdown"
        room.starts_in = COUNTDOWN
        for p in room.players.values():
            p.word = 0
            p.chars = 0
            p.wpm = 0
            p.acc = 100
            p.done = False
        await self.broadcast(room)
        room.countdown_task = asyncio.create_task(self.countdown(room))

    async def countdown(self, room: Room) -> None:
        try:
            for remaining in range(COUNTDOWN, 0, -1):
                room.starts_in = remaining
                await self.broadcast(room)
                await asyncio.sleep(1)
                if room.code not in self.rooms or room.phase != "countdown":
                    return
            room.phase = "race"
            room.starts_in = 0
            room.started_at = now()
            room.ends_at = room.started_at + room.amount
            await self.broadcast(room)
            ticker = asyncio.create_task(self.race_ticker(room))
            await asyncio.sleep(room.amount)
            ticker.cancel()
            if room.code in self.rooms and room.phase == "race":
                room.phase = "done"
                await self.broadcast(room)
        except asyncio.CancelledError:
            pass

    async def race_ticker(self, room: Room) -> None:
        """Standings twice a second: progress messages stay cheap, screens live."""
        try:
            while room.code in self.rooms and room.phase == "race":
                await self.broadcast(room)
                await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            pass

    def ranking(self, room: Room) -> list[dict]:
        rows = [p.public() for p in room.players.values()]
        rows.sort(key=lambda p: (not p["done"], -p["chars"], -p["wpm"]))
        for i, row in enumerate(rows, 1):
            row["rank"] = i
        return rows

    async def broadcast(self, room: Room) -> None:
        dead: list[str] = []
        stand = self.ranking(room)
        for player in list(room.players.values()):
            if player.ws is None:
                continue
            try:
                # The payload cannot be shared: `you` differs per player, and a
                # client that reads somebody else's id thinks it is the host.
                state = room.state(player)
                state["standings"] = stand
                player.ws.write(encode_frame(json.dumps(state).encode()))
                await player.ws.drain()
            except (ConnectionResetError, BrokenPipeError):
                dead.append(player.pid)
        for pid in dead:
            room.players.pop(pid, None)

    async def sweep(self) -> None:
        while True:
            await asyncio.sleep(60)
            stamp = now()
            for code, room in list(self.rooms.items()):
                empty = not room.players and stamp - room.touched > EMPTY_TIMEOUT
                idle = stamp - room.touched > IDLE_TIMEOUT
                if empty or idle:
                    if room.countdown_task:
                        room.countdown_task.cancel()
                    self.rooms.pop(code, None)


async def main() -> int:
    parser = argparse.ArgumentParser(description="typer static + race server")
    parser.add_argument("--root", required=True, help="directory to serve")
    parser.add_argument("--port", type=int, default=9146)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    root = os.path.realpath(args.root)
    if not os.path.isdir(root):
        print(f"root is not a directory: {root}", file=sys.stderr)
        return 1

    app = RaceServer(root)
    server = await asyncio.start_server(app.handle, args.host, args.port, limit=65536)
    print(
        f"typer: serving {root} and /ws on http://{args.host}:{args.port} "
        f"(langs: {', '.join(sorted(app.pools))})",
        flush=True,
    )
    sweep = asyncio.create_task(app.sweep())
    try:
        async with server:
            await server.serve_forever()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        sweep.cancel()
        server.close()
        await server.wait_closed()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
