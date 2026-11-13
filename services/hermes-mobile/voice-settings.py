"""Réglages de voix du client vocal Hermes.

Petit service HTTP local (127.0.0.1) proxifié par nginx sous /voice/api/ sur le
domaine mobile. Il porte trois choses que le backend `hermes serve` ne sait pas
faire :

- un état persistant (moteur, voix, vitesse, hauteur) dans
  ~/.hermes/voice-settings.json ;
- le catalogue des voix disponibles (edge-tts, filtré sur les langues utiles) ;
- la synthèse, pour les aperçus ET pour la conversation : la page web parle via
  ce service, donc changer de voix est immédiat, sans redémarrage ni rebuild.

Endpoints (préfixe retiré par nginx) :
  GET  /state                      -> état courant
  POST /state   {engine,voice,rate,pitch} -> valide + enregistre
  GET  /voices                     -> {engines:[...], state}
  POST /preview {text?, ...override} -> audio/mpeg (aperçu)
  POST /speak   {text,   ...override} -> audio/mpeg (conversation)

Aucune dépendance hors stdlib + edge-tts. Écrit uniquement dans le fichier
d'état ; les fichiers audio sont rendus en mémoire et jamais laissés sur disque.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import edge_tts

HOST = "127.0.0.1"
PORT = int(os.environ.get("VOICE_SETTINGS_PORT", "9134"))
STATE_PATH = Path(
    os.environ.get(
        "VOICE_SETTINGS_STATE",
        str(Path.home() / ".hermes" / "voice-settings.json"),
    )
)
# Langues proposées : français d'abord (usage réel), puis les multilingues.
LANGS = ("fr-", "en-GB", "en-US")
DEFAULT_STATE: dict[str, Any] = {
    "engine": "edge",
    "voice": "fr-FR-VivienneMultilingualNeural",
    "rate": 0,      # pourcentage, -50..+50
    "pitch": 0,     # Hz, -30..+30
    "volume": 0,    # pourcentage, -50..+50
}
MAX_TEXT = 4000

_lock = threading.Lock()
_voices_cache: dict[str, Any] = {"at": 0.0, "by_id": {}, "list": []}
_VOICES_TTL = 3600


def read_state() -> dict[str, Any]:
    try:
        with STATE_PATH.open() as fh:
            saved = json.load(fh)
    except (OSError, ValueError):
        return dict(DEFAULT_STATE)
    state = dict(DEFAULT_STATE)
    if isinstance(saved, dict):
        state.update({k: saved[k] for k in DEFAULT_STATE if k in saved})
    return state


def write_state(patch: dict[str, Any]) -> dict[str, Any]:
    state = read_state()
    if "engine" in patch and isinstance(patch["engine"], str):
        state["engine"] = patch["engine"]
    if "voice" in patch and isinstance(patch["voice"], str) and patch["voice"].strip():
        state["voice"] = patch["voice"].strip()
    for key, lo, hi in (("rate", -50, 50), ("pitch", -30, 30), ("volume", -50, 50)):
        if key in patch:
            try:
                value = int(round(float(patch[key])))
            except (TypeError, ValueError):
                continue
            state[key] = max(lo, min(hi, value))
    with _lock:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".tmp")
        with tmp.open("w") as fh:
            json.dump(state, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, STATE_PATH)
    return state


def _label(short_name: str, gender: str | None) -> str:
    base = short_name.split("-")[-1]
    base = re.sub(r"Neural$", "", base)
    base = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", base)
    if gender:
        base += " (F)" if gender.upper().startswith("F") else " (H)"
    return base


def voices() -> list[dict[str, Any]]:
    now = time.time()
    if _voices_cache["list"] and now - _voices_cache["at"] < _VOICES_TTL:
        return _voices_cache["list"]
    rows = asyncio.run(edge_tts.list_voices())
    out: list[dict[str, Any]] = []
    for v in rows:
        short = v.get("ShortName", "")
        if not any(short.startswith(lang) for lang in LANGS):
            continue
        out.append(
            {
                "id": short,
                "label": _label(short, v.get("Gender")),
                "gender": v.get("Gender"),
                "lang": short.split("-")[0],
                "multilingual": "Multilingual" in short,
            }
        )
    out.sort(key=lambda x: (not x["lang"].startswith("fr"), x["lang"], x["label"]))
    if out:
        _voices_cache.update({"at": now, "list": out, "by_id": {v["id"]: v for v in out}})
    return out


def _pct(n: int) -> str:
    return f"{n:+d}%"


def _hz(n: int) -> str:
    return f"{n:+d}Hz"


async def _synthesize(text: str, opts: dict[str, Any]) -> bytes:
    communicate = edge_tts.Communicate(
        text,
        opts["voice"],
        rate=_pct(int(opts["rate"])),
        pitch=_hz(int(opts["pitch"])),
        volume=_pct(int(opts["volume"])),
    )
    chunks: list[bytes] = []
    async for message in communicate.stream():
        if message.get("type") == "audio":
            chunks.append(message["data"])
    return b"".join(chunks)


def synthesize(text: str, override: dict[str, Any] | None = None) -> bytes:
    state = read_state()
    if override:
        state = {**state, **{k: override[k] for k in DEFAULT_STATE if k in override}}
    if not state["voice"]:
        state["voice"] = DEFAULT_STATE["voice"]
    return asyncio.run(_synthesize(text, state))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    # --- helpers ---------------------------------------------------------
    def _json(self, code: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _audio(self, data: bytes) -> None:
        self.send_response(200)
        self.send_header("content-type", "audio/mpeg")
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw)
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    # --- routes ----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        try:
            if path in ("/", "/state"):
                return self._json(200, {"ok": True, "state": read_state()})
            if path == "/voices":
                catalogue = voices()
                return self._json(
                    200,
                    {
                        "ok": True,
                        "state": read_state(),
                        "engines": [
                            {
                                "id": "edge",
                                "name": "Edge (gratuit, rapide)",
                                "note": "Voix neuronales Microsoft, ~1 s par phrase.",
                                "voices": catalogue,
                            }
                        ],
                    },
                )
            if path == "/healthz":
                return self._json(200, {"ok": True})
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"ok": False, "error": str(exc)})
        return self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        payload = self._body()
        try:
            if path == "/state":
                return self._json(200, {"ok": True, "state": write_state(payload)})
            if path in ("/preview", "/speak"):
                text = str(payload.get("text") or "").strip()
                if not text:
                    text = "Bonjour Marc, voilà ma voix. Dis-moi si elle te va."
                if len(text) > MAX_TEXT:
                    text = text[:MAX_TEXT]
                override = {k: payload[k] for k in DEFAULT_STATE if k in payload and k != "engine"}
                audio = synthesize(text, override)
                if not audio:
                    return self._json(502, {"ok": False, "error": "synthèse vide"})
                return self._audio(audio)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"ok": False, "error": str(exc)})
        return self._json(404, {"ok": False, "error": "not found"})


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"voice-settings: http://{HOST}:{PORT} (état {STATE_PATH})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
