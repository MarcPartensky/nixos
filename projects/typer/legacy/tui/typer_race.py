#!/usr/bin/env python3
"""typer-race: terminal client for typer.marcpartensky.com race rooms.

Curses UI, Python stdlib only (no pip, no build): the same four-character room
as the browser, the same word stream, the same ranking. Anybody with a shell
and python3 can join a race; --url points it at another server.

    typer-race                       create a room, print its code
    typer-race --room ABCD           join room ABCD
    typer-race --name marc --time 60
    typer-race --url ws://127.0.0.1:9146/ws

Keys: letters and space type, backspace corrects, r toggles ready (lobby) or
restarts (final ranking), t cycles duration, l cycles word list, q quits.
"""

from __future__ import annotations

import argparse
import base64
import curses
import getpass
import hashlib
import json
import locale
import os
import select
import socket
import ssl
import sys
import time
from urllib.parse import urlsplit

AMOUNTS = (15, 30, 60, 120)
LANGS = (("english200", "english 200"), ("english1000", "english 1000"),
         ("french200", "français 200"), ("french1000", "français 1000"))

STRINGS = {
    "fr": {
        "lobby": "salon",
        "ready": "prêt",
        "notready": "pas prêt",
        "waiting": "en attente des autres",
        "countdown": "départ dans",
        "racing": "en course",
        "done": "terminé",
        "rank": "classement",
        "you": "toi",
        "host": "hôte",
        "room": "salle",
        "share": "lien",
        "lost": "connexion perdue",
        "hint.lobby": "r prêt · t durée · l liste · q quitter",
        "hint.race": "tape · q quitter",
        "hint.done": "r revanche · q quitter",
        "wpm": "mots/min",
        "acc": "préc",
        "errors": "erreurs",
        "left": "restant",
        "words": "mots",
        "name": "nom",
        "error": "erreur",
    },
    "en": {
        "lobby": "lobby",
        "ready": "ready",
        "notready": "not ready",
        "waiting": "waiting for the others",
        "countdown": "starting in",
        "racing": "racing",
        "done": "finished",
        "rank": "ranking",
        "you": "you",
        "host": "host",
        "room": "room",
        "share": "link",
        "lost": "connection lost",
        "hint.lobby": "r ready · t duration · l word list · q quit",
        "hint.race": "type · q quit",
        "hint.done": "r rematch · q quit",
        "wpm": "wpm",
        "acc": "acc",
        "errors": "errors",
        "left": "left",
        "words": "words",
        "name": "name",
        "error": "error",
    },
}


# ------------------------------------------------------------ websocket ---


class Closed(Exception):
    pass


class WS:
    """Minimal RFC 6455 client: text frames, ping/pong, close, no extensions."""

    def __init__(self, url: str, timeout: float = 10.0) -> None:
        parts = urlsplit(url)
        host = parts.hostname or "127.0.0.1"
        port = parts.port or (443 if parts.scheme == "wss" else 80)
        path = parts.path or "/ws"
        if parts.query:
            path += "?" + parts.query
        raw = socket.create_connection((host, port), timeout=timeout)
        if parts.scheme == "wss":
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "User-Agent: typer-race\r\n\r\n"
        )
        raw.sendall(request.encode("latin-1"))
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = raw.recv(4096)
            if not chunk:
                raise Closed("handshake closed")
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n")[0]
        if b" 101 " not in status:
            raise Closed(status.decode("latin-1", "replace"))
        expected = base64.b64encode(
            hashlib.sha1(key.encode() + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()
        ).decode()
        if expected.encode() not in head:
            raise Closed("bad Sec-WebSocket-Accept")
        self.sock = raw
        self.buf = rest

    # -- frame layer -------------------------------------------------------

    def _frame(self) -> tuple[int, bytes] | None:
        b = self.buf
        if len(b) < 2:
            return None
        opcode = b[0] & 0x0F
        length = b[1] & 0x7F
        offset = 2
        masked = b[1] & 0x80
        if length == 126:
            if len(b) < 4:
                return None
            length = int.from_bytes(b[2:4], "big")
            offset = 4
        elif length == 127:
            if len(b) < 10:
                return None
            length = int.from_bytes(b[2:10], "big")
            offset = 10
        if masked:
            offset += 4
        if len(b) < offset + length:
            return None
        payload = b[offset : offset + length]
        self.buf = b[offset + length :]
        return opcode, payload

    def send(self, message: dict) -> None:
        data = json.dumps(message).encode("utf-8")
        header = bytearray([0x81])
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += n.to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += n.to_bytes(8, "big")
        mask = os.urandom(4)
        header += mask
        header += bytes(data[i] ^ mask[i % 4] for i in range(n))
        self.sock.sendall(bytes(header))

    def poll(self, timeout: float) -> dict | None:
        """Next JSON message, or None if the timeout expires."""
        end = time.monotonic() + timeout
        while True:
            frame = self._frame()
            if frame is not None:
                opcode, payload = frame
                if opcode == 0x8:
                    raise Closed("server closed")
                if opcode == 0x9:
                    self.sock.sendall(bytes([0x8A, len(payload)]) + payload)
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                try:
                    return json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
            remain = end - time.monotonic()
            if remain <= 0:
                return None
            ready, _, _ = select.select([self.sock], [], [], remain)
            if not ready:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed("socket closed")
            self.buf += chunk

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# ------------------------------------------------------------------ run ---


class Run:
    """Local typing state; the server owns the words and the clock."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.words: list[str] = []
        self.typed: dict[int, str] = {}
        self.index = 0
        self.started = False
        self.ended = False
        self.start = 0.0
        self.keys = 0
        self.errors = 0
        self.wrong: set[int] = set()

    @property
    def elapsed(self) -> float:
        if not self.started:
            return 0.001
        return max(0.001, time.monotonic() - self.start)

    def correct(self) -> int:
        total = 0
        for i, text in self.typed.items():
            word = self.words[i] if i < len(self.words) else ""
            for j, ch in enumerate(text):
                if j < len(word) and word[j] == ch:
                    total += 1
        return total

    def wpm(self) -> int:
        return round(self.correct() / 5 / (self.elapsed / 60))

    def acc(self) -> float:
        if not self.keys:
            return 100.0
        return max(0.0, 100 * (1 - self.errors / self.keys))

    def feed(self, ch: str) -> None:
        if self.ended or not self.words:
            return
        if not self.started:
            self.started = True
            self.start = time.monotonic()
        if ch == " ":
            text = self.typed.get(self.index, "")
            if not text:
                return
            self.keys += 1
            if text != self.words[self.index]:
                self.errors += 1
                self.wrong.add(self.index)
            self.index += 1
            if self.index >= len(self.words):
                self.ended = True
            return
        word = self.words[self.index]
        text = self.typed.get(self.index, "")
        if len(text) >= len(word) + 4:
            return
        self.typed[self.index] = text + ch
        self.keys += 1
        if len(text) >= len(word) or word[len(text)] != ch:
            self.errors += 1
            self.wrong.add(self.index)

    def backspace(self) -> None:
        if self.ended:
            return
        text = self.typed.get(self.index, "")
        if text:
            self.typed[self.index] = text[:-1]
            return
        if self.index:
            prev = self.index - 1
            if self.typed.get(prev, "") == self.words[prev]:
                return
            self.index = prev
            self.typed[prev] = self.typed.get(prev, "")[:-1]

    def snapshot(self) -> dict:
        return {
            "t": "progress",
            "word": self.index,
            "chars": self.correct(),
            "wpm": self.wpm(),
            "acc": round(self.acc(), 1),
        }


# ------------------------------------------------------------------- UI ---


class App:
    def __init__(self, screen, url: str, room: str, name: str, lang: str, amount: int, ui: str) -> None:
        self.screen = screen
        self.url = url
        self.ui = ui
        self.s = STRINGS[ui]
        self.name = name
        self.lang = lang
        self.amount = amount
        self.room = room.upper() if room else ""
        self.state: dict | None = None
        self.me: str | None = None
        self.run = Run()
        self.error = ""
        self.last_send = 0.0
        self.reported = False
        self.dirty = True

        self.ws = WS(url)
        self.ws.send(
            {
                "t": "join",
                "room": self.room,
                "name": name,
                "lang": lang,
                "amount": amount,
            }
        )

    # -- socket ------------------------------------------------------------

    def pump(self) -> None:
        message = self.ws.poll(0.01)
        if message is None:
            return
        self.dirty = True
        kind = message.get("t")
        if kind == "error":
            self.error = self.s["error"] + ": " + str(message.get("error"))
            return
        if kind != "state":
            return
        previous = (self.state or {}).get("phase")
        self.state = message
        self.room = message.get("room", self.room)
        self.me = message.get("you")
        phase = message["phase"]

        if phase == "race" and previous != "race":
            self.run.reset()
            self.run.words = list(message.get("words") or [])
            self.run.started = True
            self.run.start = time.monotonic()
            self.reported = False
        if phase == "lobby" and previous in ("done", "race", "countdown"):
            self.run.reset()
        if phase == "done":
            self.run.ended = True
        if phase != "race":
            self.run.started = self.run.started if phase == "done" else False

    def send_progress(self) -> None:
        now = time.monotonic()
        if now - self.last_send < 0.4:
            return
        self.last_send = now
        self.ws.send(self.run.snapshot())

    def report_done(self) -> None:
        if self.reported:
            return
        self.reported = True
        snapshot = self.run.snapshot()
        snapshot["t"] = "done"
        self.ws.send(snapshot)

    def leave(self) -> None:
        try:
            self.ws.send({"t": "leave"})
            self.ws.close()
        except (OSError, Closed):
            pass

    # -- drawing helpers ---------------------------------------------------

    def put(self, y: int, x: int, text: str, attr: int = 0, width: int | None = None) -> int:
        h, w = self.screen.getmaxyx()
        if y < 0 or y > h - 1 or x >= w - 1:
            return x
        limit = w - 1 if width is None else min(w - 1, x + width)
        room = limit - x
        if room <= 0:
            return x
        try:
            self.screen.addstr(y, x, text[:room], attr)
        except curses.error:
            pass
        return x + min(len(text), room)

    def wrap(self, width: int) -> list[list[tuple[int, str]]]:
        rows: list[list[tuple[int, str]]] = []
        row: list[tuple[int, str]] = []
        used = 0
        for i, word in enumerate(self.run.words):
            need = len(word) + (1 if row else 0)
            if used + need > width and row:
                rows.append(row)
                row = []
                used = 0
                need = len(word)
            row.append((i, word))
            used += need
        if row:
            rows.append(row)
        return rows

    def draw_words(self, y0: int, height: int, width: int) -> None:
        rows = self.wrap(max(10, width - 1))
        if not rows:
            return
        active = 0
        for idx, line in enumerate(rows):
            if any(word_i == self.run.index for word_i, _ in line):
                active = idx
                break
            if line[0][0] > self.run.index:
                active = max(0, idx - 1)
                break
            active = idx
        start = max(0, active - (height - 1) // 2)
        for offset in range(height):
            row_index = start + offset
            if row_index >= len(rows):
                break
            x = 0
            for word_i, word in rows[row_index]:
                if x >= width - 1:
                    break
                typed = self.run.typed.get(word_i, "")
                attr_plain = curses.A_DIM | curses.color_pair(1)
                for j, ch in enumerate(word):
                    if j < len(typed):
                        attr = (
                            curses.color_pair(3)
                            if typed[j] == ch
                            else curses.A_BOLD | curses.color_pair(4)
                        )
                    else:
                        attr = attr_plain
                    if word_i == self.run.index and j == len(typed) and not self.run.ended:
                        attr = curses.A_REVERSE | curses.color_pair(2)
                    self.put(y0 + offset, x, ch, attr, 1)
                    x += 1
                for j in range(len(word), len(typed)):
                    self.put(y0 + offset, x, typed[j], curses.A_BOLD | curses.color_pair(4), 1)
                    x += 1
                if x < width - 1:
                    if word_i == self.run.index and len(typed) >= len(word) and not self.run.ended:
                        self.put(y0 + offset, x, " ", curses.A_REVERSE | curses.color_pair(2), 1)
                    x += 1

    def board(self) -> list[dict]:
        state = self.state or {}
        players = list(state.get("standings") or state.get("players") or [])
        players.sort(key=lambda p: (p.get("rank") or 99, -p.get("chars", 0)))
        return players

    def draw(self) -> None:
        screen = self.screen
        h, w = screen.getmaxyx()
        screen.erase()
        state = self.state or {}
        phase = state.get("phase", "lobby")
        players = self.board()
        me = next((p for p in players if p.get("id") == self.me), {})
        s = self.s

        # Header: brand, room, phase, clock.
        title = f" typer-race  {s['room']} {self.room or '····'} "
        self.put(0, 0, title, curses.A_BOLD | curses.color_pair(2))
        label = {
            "lobby": s["lobby"],
            "countdown": s["countdown"],
            "race": s["racing"],
            "done": s["done"],
        }.get(phase, phase)
        label = str(label or phase)
        clock = ""
        if phase == "countdown":
            clock = str(max(1, int(state.get("startsIn") or 1)))
        elif phase == "race":
            clock = f"{int(max(0, state.get('endsIn') or 0))}s"
        status = f"{label} {clock}".strip()
        self.put(0, max(len(title) + 1, w - len(status) - 1), status, curses.color_pair(5))

        # HUD on the left, settings on the right, never on top of each other.
        wpm = me.get("wpm") if phase in ("race", "done") else self.run.wpm()
        acc = me.get("acc") if phase in ("race", "done") else round(self.run.acc(), 1)
        err = self.run.errors if phase in ("race", "done") else 0
        hud = f" {wpm} {s['wpm']}   {acc:.0f}% {s['acc']}   {err} {s['errors']}"
        config = f"{self.lang} · {self.amount}s · {self.name} "
        if w - len(hud) - len(config) > 2:
            self.put(1, 0, hud, curses.color_pair(1))
            self.put(1, w - len(config), config, curses.color_pair(1))
        else:
            self.put(1, 0, hud[: max(0, w - 1)], curses.color_pair(1))

        # Bottom-up reservation: hint, players, lobby/report lines, then words.
        hint = s["hint." + ("race" if phase == "race" else "done" if phase == "done" else "lobby")]
        players_h = min(len(players), 6) + (1 if phase == "done" else 0)
        info_h = 2 if phase in ("lobby", "countdown") else 0
        words_h = max(3, h - 2 - players_h - info_h - 1)
        self.draw_words(2, words_h, w)

        y = 2 + words_h
        if phase == "lobby":
            ready = bool(me.get("ready"))
            self.put(y, 0, f" {s['ready'] if ready else s['notready']} · {s['waiting']}", curses.color_pair(5))
            self.put(y + 1, 0, f" {s['share']}: {self.http_link()}", curses.color_pair(1))
            y += 2
        elif phase == "countdown":
            self.put(y, 0, f" {s['countdown']} {clock}…", curses.A_BOLD | curses.color_pair(5))
            y += 2
        elif phase == "done":
            self.put(y, 0, f" {s['rank']}", curses.A_BOLD | curses.color_pair(5))
            y += 1

        for i, player in enumerate(players[:6]):
            row = y + i
            if row >= h - 1:
                break
            who = player.get("name", "?")
            tags = []
            if player.get("id") == self.me:
                tags.append(s["you"])
            if player.get("id") == state.get("host"):
                tags.append(s["host"])
            suffix = f" ({', '.join(tags)})" if tags else ""
            label_text = f" {i + 1:>2} {who[:14]:<14}{suffix:<10}"
            bar_width = max(6, min(28, w - len(label_text) - 12))
            top = max(1, max((p.get("chars", 0) for p in players), default=1))
            filled = round(bar_width * player.get("chars", 0) / top)
            bar = "#" * filled + "-" * (bar_width - filled)
            attr = curses.A_BOLD if player.get("id") == self.me else curses.A_NORMAL
            line = f"{label_text} {player.get('wpm', 0):>4} {bar} {player.get('acc', 0):.0f}%"
            self.put(row, 0, line, attr | curses.color_pair(2 if player.get("id") == self.me else 1))

        self.put(h - 1, 0, " " + hint, curses.color_pair(1))
        if self.error:
            self.put(h - 1, max(0, w - len(self.error) - 1), self.error, curses.A_BOLD | curses.color_pair(4))
        screen.refresh()

    def http_link(self) -> str:
        base = self.url
        if base.startswith("wss://"):
            base = "https://" + base[6:]
        elif base.startswith("ws://"):
            base = "http://" + base[5:]
        base = base.split("/ws")[0].rstrip("/")
        return f"{base}/#room={self.room}"

    # -- keys --------------------------------------------------------------

    def host(self) -> bool:
        return bool(self.state and self.state.get("host") == self.me)

    def handle(self, ch: str) -> bool:
        state = self.state or {}
        phase = state.get("phase", "lobby")
        if ch in ("q", "Q") or ch == "\x03":
            return False
        if ch == "\x1b":
            return False
        if ch in ("\x7f", "\x08"):
            self.run.backspace()
            self.dirty = True
            return True
        if phase == "lobby":
            if ch in ("r", "R"):
                me = next((p for p in (state.get("players") or []) if p.get("id") == self.me), {})
                self.ws.send({"t": "ready", "ready": not me.get("ready")})
            elif ch in ("t", "T") and self.host():
                self.amount = AMOUNTS[(AMOUNTS.index(self.amount) + 1) % len(AMOUNTS)] if self.amount in AMOUNTS else 30
                self.ws.send({"t": "settings", "lang": self.lang, "amount": self.amount})
            elif ch in ("l", "L") and self.host():
                ids = [i for i, _ in LANGS]
                self.lang = ids[(ids.index(self.lang) + 1) % len(ids)] if self.lang in ids else ids[0]
                self.ws.send({"t": "settings", "lang": self.lang, "amount": self.amount})
            return True
        if phase == "done":
            if ch in ("r", "R"):
                self.ws.send({"t": "rematch"})
            return True
        if phase != "race":
            return True
        if ch == " ":
            self.run.feed(" ")
        elif len(ch) == 1 and ch.isprintable():
            self.run.feed(ch)
        self.dirty = True
        return True

    def loop(self) -> None:
        self.screen.timeout(30)
        running = True
        last_draw = 0.0
        while running:
            try:
                self.pump()
            except (OSError, Closed) as exc:
                self.error = f"{self.s['lost']}: {exc}"
                self.dirty = True
                self.draw()
                time.sleep(1.5)
                break

            phase = (self.state or {}).get("phase", "lobby")
            if phase == "race":
                self.send_progress()
                if self.run.ended:
                    self.report_done()

            now = time.monotonic()
            if self.dirty or now - last_draw > 0.1:
                self.draw()
                self.dirty = False
                last_draw = now

            try:
                ch = self.screen.get_wch()
            except curses.error:
                continue
            if isinstance(ch, int):
                continue
            running = self.handle(ch)


def pick_ui() -> str:
    return "fr" if (os.environ.get("LANG") or "").lower().startswith("fr") else "en"


def main() -> int:
    parser = argparse.ArgumentParser(description="terminal client for typer race rooms")
    parser.add_argument("--url", default="wss://typer.marcpartensky.com/ws")
    parser.add_argument("--room", default="", help="four-character room code (empty: create one)")
    parser.add_argument("--name", default=os.environ.get("TYPER_NAME") or getpass.getuser())
    parser.add_argument("--lang", default="", help="english200, english1000, french200, french1000")
    parser.add_argument("--time", type=int, default=30, choices=AMOUNTS)
    parser.add_argument("--ui", default=pick_ui(), choices=("fr", "en"))
    args = parser.parse_args()

    lang = args.lang
    if not lang:
        lang = "french200" if args.ui == "fr" else "english200"
    if lang not in [i for i, _ in LANGS]:
        print(f"unknown word list: {lang}", file=sys.stderr)
        return 2

    locale.setlocale(locale.LC_ALL, "")
    app: App | None = None

    def start(screen):
        nonlocal app
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        curses.start_color()
        try:
            curses.use_default_colors()
            bg = -1
        except curses.error:
            bg = curses.COLOR_BLACK
        curses.init_pair(1, curses.COLOR_CYAN if curses.COLORS >= 8 else curses.COLOR_WHITE, bg)
        curses.init_pair(2, curses.COLOR_WHITE, bg)
        curses.init_pair(3, curses.COLOR_GREEN, bg)
        curses.init_pair(4, curses.COLOR_RED, bg)
        curses.init_pair(5, curses.COLOR_MAGENTA, bg)
        app = App(screen, args.url, args.room, args.name, lang, args.time, args.ui)
        app.loop()

    try:
        curses.wrapper(start)
    finally:
        if app is not None:
            app.leave()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
