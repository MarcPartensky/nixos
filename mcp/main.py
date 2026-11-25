#!/usr/bin/env python3
# mcp/main.py
# A single MCP process hosting all the in-house servers.
#
# Why: today each Hermes session starts one process per server
# (32 per session, 133 measured on tower), each with its own Python
# interpreter and its copy of the SDK. Measurement: 54 MB of RSS and 910 ms of startup per
# process, of which 33 ms of interpreter and 1005 ms of SDK import. A single
# process pays that once.
#
# How the existing servers are reused WITHOUT being modified: they do
# `from mcp.server.fastmcp import FastMCP`, which has no composition. So a shim
# is installed in sys.modules so that this name resolves to the standalone
# package `fastmcp` (3.2.3 in nixpkgs), which has import_server / mount. Gain
# measured on 5 real servers: import of 16 to 37 ms each, no failure.
#
# Adding an existing server: an entry in the JSON manifest (name -> path
# of the .py). Adding a new tool without restarting: drop a file in the
# modules directory (decorator `from fastmcp.tools import tool`), served by the
# FileSystemProvider.
import importlib.util
import json
import os
import sys
import types
from pathlib import Path

import fastmcp
from fastmcp import FastMCP
from fastmcp.server.providers import FileSystemProvider


def _install_shim() -> None:
    """Makes `mcp.server.fastmcp` point to the standalone fastmcp package.

    The existing servers import FastMCP from the official SDK, which cannot
    compose. Their code is not touched: the import target is
    replaced. sys.modules is consulted before disk, so the shim wins.
    """
    fm = types.ModuleType("mcp.server.fastmcp")
    fm.FastMCP = fastmcp.FastMCP
    sys.modules.setdefault("mcp", types.ModuleType("mcp"))
    sys.modules.setdefault("mcp.server", types.ModuleType("mcp.server"))
    sys.modules["mcp.server.fastmcp"] = fm


def _load_server(name: str, path: str):
    """Imports an existing server by path and returns its FastMCP instance."""
    spec = importlib.util.spec_from_file_location(f"hermes_mcp_{name.replace('-', '_')}", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"{name}: unreadable path ({path})")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for attr in ("mcp", "app", "server"):
        candidate = getattr(module, attr, None)
        if isinstance(candidate, FastMCP):
            return candidate
    raise AttributeError(f"{name}: no FastMCP object (mcp/app/server) in {path}")


def _load_stdio_manifest(path: str) -> dict:
    """Loads the manifest of stdio servers to proxy (name -> command).

    Shape: {"gitea": {"command": "...", "args": [...], "env": {...}}, ...}.
    These servers are started BY THE DAEMON, once for all sessions,
    instead of one process per Hermes session (measurement of 21/11/2026: 26
    stdio servers x 5 sessions = 103 processes, 322 threads, 10.6 GB).
    """
    p = Path(path)
    if not p.is_file():
        return {}
    try:
        return json.loads(p.read_text())
    except Exception as exc:
        print(f"[mcp-host] unreadable stdio manifest ({path}): {exc}", file=sys.stderr)
        return {}


def _mount_stdio_proxy(root: FastMCP, name: str, spec: dict) -> None:
    """Mounts an existing stdio server as a proxy, without modifying its code.

    The proxy is lazy: the child is started only on the first request that
    touches its tools, and the same child serves ALL Hermes sessions.
    `namespace=name` is essential: without it the 26 servers expose their
    tools flat and 57 tools with the same name overwrite each other (measurement: 459 tools
    instead of 516). With it, each tool becomes `<server>_<tool>`.
    """
    from fastmcp.client import Client, StdioTransport
    from fastmcp.server import create_proxy

    transport = StdioTransport(
        command=spec["command"],
        args=list(spec.get("args") or []),
        env={**os.environ, **(spec.get("env") or {})},
    )
    root.mount(create_proxy(Client(transport, name=name), name=name), namespace=name)


def build(manifest: dict, modules_dir: Path | None, stdio: dict | None = None) -> FastMCP:
    """Builds the root server: existing servers + hot modules."""
    _install_shim()
    root = FastMCP("hermes-tools")
    failed = {}
    for name, path in sorted(manifest.items()):
        try:
            # mount() is synchronous and establishes a dynamic connection;
            # import_server() is async (copy at import): do not call it
            # without await, otherwise no tool is mounted and no error is
            # raised (the only symptom is a RuntimeWarning).
            # No namespace: the tools already carry their app's prefix
            # (shlink_health, beef_logs...), so renaming them would break the skills
            # and crons that cite them by their full name.
            root.mount(_load_server(name, path))
        except Exception as exc:  # a broken server must not prevent the others
            failed[name] = f"{type(exc).__name__}: {exc}"
    for name, spec in sorted((stdio or {}).items()):
        try:
            _mount_stdio_proxy(root, name, spec)
        except Exception as exc:
            failed[f"stdio:{name}"] = f"{type(exc).__name__}: {exc}"
    if modules_dir and modules_dir.is_dir():
        # reload=True: without it, FileSystemProvider scans the directory only
        # once at startup, so dropping a .py into /var/lib/mcp/modules
        # exposes nothing before a daemon restart (observed on 14/11/2026:
        # adguard.py placed, 99 tools served, no adguard_*). The re-scan happens
        # per request, on a directory of a few files: zero cost.
        root.add_provider(FileSystemProvider(modules_dir, reload=True), namespace="")
    for name, err in failed.items():
        print(f"[mcp-host] FAILURE {name}: {err}", file=sys.stderr)
    return root


def main() -> None:
    manifest_path = os.environ.get("MCP_HOST_MANIFEST", "/etc/mcp-host/servers.json")
    modules_dir = Path(os.environ.get("MCP_HOST_MODULES", "/var/lib/mcp/modules"))
    host = os.environ.get("MCP_HOST_ADDR", "127.0.0.1")
    port = int(os.environ.get("MCP_HOST_PORT", "4780"))

    manifest = {}
    p = Path(manifest_path)
    if p.is_file():
        manifest = json.loads(p.read_text())
    else:
        print(f"[mcp-host] manifest absent ({manifest_path}), starting with modules only", file=sys.stderr)

    stdio = _load_stdio_manifest(os.environ.get("MCP_HOST_STDIO", "/etc/mcp-host/stdio.json"))
    if stdio:
        print(f"[mcp-host] {len(stdio)} stdio servers proxied by this daemon", file=sys.stderr)

    root = build(manifest, modules_dir, stdio)
    print(f"[mcp-host] {len(manifest)} servers + {modules_dir} on http://{host}:{port}/mcp", file=sys.stderr)
    # Configurable transport: this machine's Hermes runtime does not have
    # mcp.client.streamable_http, so streamable-http fails with
    # "requires HTTP transport but ... not available". SSE, however, works.
    transport = os.environ.get("MCP_HOST_TRANSPORT", "sse")
    print(
        f"[mcp-host] {len(manifest)} servers + {modules_dir} on "
        f"http://{host}:{port} (transport {transport})",
        file=sys.stderr,
    )
    root.run(transport=transport, host=host, port=port)


if __name__ == "__main__":
    main()
