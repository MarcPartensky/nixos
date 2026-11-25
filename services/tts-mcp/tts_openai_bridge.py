"""OpenAI-compatible text-to-speech facade in front of the tts-mcp server.

tts-mcp speaks the Model Context Protocol (JSON-RPC over HTTP at /mcp), while
most applications (Open Notebook, Open WebUI, LiteLLM) only implement the
OpenAI audio API. This process translates one into the other:

    POST /v1/audio/speech   -> tts-mcp tool "say" (model = engine-language)
    GET  /v1/models         -> the (engine, language) pairs exposed here
    GET  /healthz           -> liveness probe

Model ids have the form "<engine>-<language>", e.g. "kokoro-fr", "omni-en" or
"kokoro-en-gb". The engine is one of the tts-mcp engines and the language is one
that engine supports. "voice" is a catalog name returned by the tts-mcp
"voices" tool; an empty voice means the engine default.

Only the standard library is used on purpose: the script must run on the
render node with the system python and no virtualenv, and it must keep working
when the tts-mcp python environment changes.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DEFAULT_MCP_URL = "http://127.0.0.1:8092/mcp"
# One render can legitimately take minutes on this node (cold model load,
# Kokoro on CPU, long paragraph), so the MCP call outlives any HTTP client
# timeout an application is likely to set.
MCP_TIMEOUT = 1200.0
MAX_TEXT = 5800  # tts-mcp "say" refuses anything above 6000 characters

# Model ids advertised on /v1/models. They are not free-form: each one is
# accepted by /v1/audio/speech as long as tts-mcp knows the engine and handles
# the language.
MODELS = [
    "kokoro-fr",
    "kokoro-en",
    "kokoro-en-gb",
    "kokoro-es",
    "kokoro-it",
    "kokoro-pt",
    "kokoro-hi",
    "kokoro-ja",
    "kokoro-zh",
    "phonon-en",
    "omni-fr",
    "omni-en",
    "cb-fr",
    "cb-en",
    "ming-fr",
    "ming-en",
]

CONTENT_TYPES = {
    "mp3": "audio/mpeg",
    "wav": "audio/wav",
}

# Applications that were written against OpenAI hardcode OpenAI voice names
# ("alloy", "nova", ...). They are meaningless for a local engine, so map them
# to a sensible catalog voice instead of failing: this keeps the stock Open
# Notebook speaker profiles usable without editing them.
OPENAI_VOICES = {
    "alloy",
    "ash",
    "ballad",
    "coral",
    "echo",
    "fable",
    "marin",
    "nova",
    "onyx",
    "sage",
    "shimmer",
    "verse",
    "cedar",
}
FEMALE_HINTS = {"ballad", "coral", "fable", "marin", "nova", "sage", "shimmer"}
MALE_HINTS = {"ash", "cedar", "echo", "onyx", "verse"}
# engine -> language -> (female voice, male voice); "*" means any language.
VOICE_ALIASES = {
    "kokoro": {
        "fr": ("ff_siwis", "ff_siwis"),
        "en": ("af_heart", "am_michael"),
        "en-gb": ("bf_emma", "bm_george"),
    },
    "phonon": {"en": ("Harper", "Trevor")},
    "omni": {"*": ("female, young adult, high pitch", "male, middle-aged, moderate pitch")},
    "ming": {"*": ("female, young adult, high pitch", "male, middle-aged, moderate pitch")},
}


def resolve_voice(engine: str, language: str, voice: str) -> str | None:
    """Turn an OpenAI voice name into a catalog voice of this engine."""
    if not voice:
        return None
    name = voice.strip().lower()
    if name not in OPENAI_VOICES:
        return voice.strip()
    aliases = VOICE_ALIASES.get(engine, {})
    pair = aliases.get(language) or aliases.get("*")
    if not pair:
        return None
    if name in MALE_HINTS:
        return pair[1]
    if name in FEMALE_HINTS:
        return pair[0]
    return None


def mcp_tool_call(mcp_url: str, name: str, arguments: dict, timeout: float = MCP_TIMEOUT):
    """Call one MCP tool over the streamable-HTTP transport.

    tts-mcp runs FastMCP with stateless_http and json_response, so no session
    handshake is needed: a single JSON-RPC request gets a single JSON answer.
    """
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
    ).encode()
    request = urllib.request.Request(
        mcp_url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode())
    except urllib.error.URLError as exc:
        raise RuntimeError(f"tts-mcp unreachable at {mcp_url}: {exc}") from exc
    if "error" in payload:
        raise RuntimeError(f"tts-mcp error: {payload['error']}")
    blocks = payload.get("result", {}).get("content") or []
    if not blocks:
        raise RuntimeError(f"tts-mcp returned no content for {name}")
    return json.loads(blocks[0]["text"])


def parse_model(model: str) -> tuple[str, str]:
    """Split "<engine>-<language>" into its two parts."""
    if not model or "-" not in model:
        raise ValueError(
            f"model must look like '<engine>-<language>', got {model!r}; "
            f"available: {', '.join(sorted(MODELS))}"
        )
    engine, language = model.split("-", 1)
    if model not in MODELS:
        raise ValueError(
            f"unknown model {model!r}; available: {', '.join(sorted(MODELS))}"
        )
    return engine, language


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    mcp_url = DEFAULT_MCP_URL

    def log_message(self, format, *args):  # noqa: A002 - base class parameter name
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def _send_json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error_json(self, status: int, message: str) -> None:
        self._send_json(status, {"error": {"message": message, "type": "tts_bridge_error"}})

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path in ("/healthz", "/health"):
            host, port = urlparse(self.mcp_url).hostname, urlparse(self.mcp_url).port or 80
            try:
                with socket.create_connection((host, port), timeout=3):
                    reachable = True
            except OSError:
                reachable = False
            self._send_json(200 if reachable else 503, {"status": "ok", "mcp": reachable})
            return
        if path == "/v1/models":
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": name, "object": "model", "owned_by": "laptop-tts"}
                        for name in MODELS
                    ],
                },
            )
            return
        self._send_error_json(404, f"unknown path {path}")

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlparse(self.path).path.rstrip("/")
        if path != "/v1/audio/speech":
            self._send_error_json(404, f"unknown path {path}; POST /v1/audio/speech")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, TypeError) as exc:
            self._send_error_json(400, f"invalid JSON body: {exc}")
            return

        text = (payload.get("input") or "").strip()
        if not text:
            self._send_error_json(400, "input must be a non-empty string")
            return
        if len(text) > MAX_TEXT:
            self._send_error_json(
                413,
                f"input is {len(text)} characters; this facade renders one clip per call "
                f"and accepts at most {MAX_TEXT}. Split the text into sentences first.",
            )
            return

        response_format = (payload.get("response_format") or "mp3").lower()
        if response_format not in CONTENT_TYPES:
            self._send_error_json(
                400,
                f"response_format {response_format!r} is not supported; "
                f"use one of {', '.join(sorted(CONTENT_TYPES))}",
            )
            return

        try:
            engine, language = parse_model(payload.get("model") or "")
        except ValueError as exc:
            self._send_error_json(400, str(exc))
            return

        arguments = {
            "text": text,
            "engine": engine,
            "language": language,
            "master_audio": True,
        }
        voice = resolve_voice(engine, language, payload.get("voice") or "")
        if voice:
            arguments["voice"] = voice
        speed = payload.get("speed")
        if speed:
            try:
                arguments["speed"] = float(speed)
            except (TypeError, ValueError):
                self._send_error_json(400, f"speed must be a number, got {speed!r}")
                return

        try:
            result = mcp_tool_call(self.mcp_url, "say", arguments)
        except RuntimeError as exc:
            self._send_error_json(502, str(exc))
            return
        if not result.get("ok"):
            self._send_error_json(
                502, f"tts-mcp refused the render: {result.get('erreur') or result}"
            )
            return

        key = "wav_brut" if response_format == "wav" else "mp3_masterise"
        audio_path = result.get(key)
        if not audio_path:
            self._send_error_json(502, f"tts-mcp did not return {key}: {result}")
            return
        try:
            with open(audio_path, "rb") as handle:
                audio = handle.read()
        except OSError as exc:
            self._send_error_json(502, f"cannot read rendered audio {audio_path}: {exc}")
            return

        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPES[response_format])
        self.send_header("Content-Length", str(len(audio)))
        self.end_headers()
        self.wfile.write(audio)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="OpenAI-compatible TTS facade in front of the tts-mcp server"
    )
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8093)
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    args = parser.parse_args(argv)
    Handler.mcp_url = args.mcp_url
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(
        f"tts-openai-bridge: listening on {args.host}:{args.port}, "
        f"tts-mcp at {args.mcp_url}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
