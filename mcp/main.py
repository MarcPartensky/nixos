#!/usr/bin/env python3
# mcp/main.py
# Un seul processus MCP qui heberge tous les serveurs maison.
#
# Pourquoi : chaque session Hermes lance aujourd'hui un processus par serveur
# (32 par session, 133 mesures sur tower), chacun avec son propre interpreteur
# Python et sa copie du SDK. Mesure : 54 Mo de RSS et 910 ms de demarrage par
# processus, dont 33 ms d'interpreteur et 1005 ms d'import du SDK. Un seul
# processus paie ca une fois.
#
# Comment les serveurs existants sont repris SANS etre modifies : ils font
# `from mcp.server.fastmcp import FastMCP`, qui n'a pas de composition. On
# installe donc un shim dans sys.modules pour que ce nom resolve vers le paquet
# autonome `fastmcp` (3.2.3 dans nixpkgs), qui a import_server / mount. Gain
# mesure sur 5 serveurs reels : import de 16 a 37 ms chacun, aucun echec.
#
# Ajouter un serveur existant : une entree dans le manifeste JSON (nom -> chemin
# du .py). Ajouter un nouvel outil sans redemarrer : deposer un fichier dans le
# dossier de modules (decorateur `from fastmcp.tools import tool`), servi par le
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
    """Fait pointer `mcp.server.fastmcp` vers le paquet autonome fastmcp.

    Les serveurs existants importent FastMCP depuis le SDK officiel, qui ne sait
    pas composer. On ne touche pas a leur code : on remplace la cible de
    l'import. sys.modules est consulte avant le disque, donc le shim gagne.
    """
    fm = types.ModuleType("mcp.server.fastmcp")
    fm.FastMCP = fastmcp.FastMCP
    sys.modules.setdefault("mcp", types.ModuleType("mcp"))
    sys.modules.setdefault("mcp.server", types.ModuleType("mcp.server"))
    sys.modules["mcp.server.fastmcp"] = fm


def _load_server(name: str, path: str):
    """Importe un serveur existant par chemin et rend son instance FastMCP."""
    spec = importlib.util.spec_from_file_location(f"hermes_mcp_{name.replace('-', '_')}", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"{name}: chemin illisible ({path})")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for attr in ("mcp", "app", "server"):
        candidate = getattr(module, attr, None)
        if isinstance(candidate, FastMCP):
            return candidate
    raise AttributeError(f"{name}: aucun objet FastMCP (mcp/app/server) dans {path}")


def build(manifest: dict, modules_dir: Path | None) -> FastMCP:
    """Construit le serveur racine : serveurs existants + modules a chaud."""
    _install_shim()
    root = FastMCP("hermes-tools")
    failed = {}
    for name, path in sorted(manifest.items()):
        try:
            # mount() est synchrone et etablit une connexion dynamique ;
            # import_server() est async (copie a l'import) : ne pas l'appeler
            # sans await, sinon aucun outil n'est monte et aucune erreur ne
            # remonte (le seul symptome est un RuntimeWarning).
            # Pas de namespace : les outils portent deja le prefixe de leur app
            # (shlink_health, beef_logs...), donc les renommer casserait les skills
            # et les crons qui les citent par leur nom complet.
            root.mount(_load_server(name, path))
        except Exception as exc:  # un serveur casse ne doit pas empecher les autres
            failed[name] = f"{type(exc).__name__}: {exc}"
    if modules_dir and modules_dir.is_dir():
        root.add_provider(FileSystemProvider(modules_dir), namespace="")
    for name, err in failed.items():
        print(f"[mcp-host] ECHEC {name}: {err}", file=sys.stderr)
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
        print(f"[mcp-host] manifeste absent ({manifest_path}), demarrage avec les modules seuls", file=sys.stderr)

    root = build(manifest, modules_dir)
    print(f"[mcp-host] {len(manifest)} serveurs + {modules_dir} sur http://{host}:{port}/mcp", file=sys.stderr)
    root.run(transport="http", host=host, port=port)


if __name__ == "__main__":
    main()
