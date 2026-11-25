# services/roku-mcp.py
# MCP server for the Roku TV (ECP, local network).
#
# Moved out of the Nix module (where it was an inline python string) for two reasons:
# a .py file mounted by modules/nixos/mcp-host is re-read without a rebuild and without
# evaluating the host config, and the host no longer evaluates a python package for it.
# Declared in profiles/tower/configuration.nix: services.mcp-host.servers.roku
# and env ROKU_URL.
#
# At the root of services/ and not in services/roku/: the ACL of that subfolder
# only gives hermes r-x (mask), so a new file cannot be created there
# by the agent. To be moved into services/roku/ the day the ACL is reopened.
#
# The mount requires a FastMCP object exposed as a module variable (here `mcp`),
# without a call to mcp.run() outside the __main__ guard: modules/nixos/mcp-host
# mounts it in the single server.
import os
import time
import urllib.request
import xml.etree.ElementTree as ET
from typing import Literal

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

TV = os.environ.get("ROKU_URL", "http://192.168.1.167:8060")

# Keys to reach the brightness setting from the HDMI input.
# To record once with the remote (key * = Info).
TO_BRIGHTNESS = ["Info", "Down"]
CLOSE = ["Back"]

mcp = MCPServer("roku-tv")


def _post(path):
    req = urllib.request.Request(f"{TV}/{path}", data=b"", method="POST")
    urllib.request.urlopen(req, timeout=5).close()


def _get(path):
    with urllib.request.urlopen(f"{TV}/{path}", timeout=5) as r:
        return ET.fromstring(r.read())


def _keys(keys, delay=0.4):
    for k in keys:
        _post(f"keypress/{k}")
        time.sleep(delay)


@mcp.tool()
def press(keys: list[str]) -> str:
    """Presses keys on the Roku remote, in order.

    Keys: Home, Back, Select, Up, Down, Left, Right, Info (*),
    Play, Rev, Fwd, InstantReplay, VolumeUp, VolumeDown, VolumeMute,
    PowerOn, PowerOff, InputHDMI1, InputHDMI2, InputHDMI3, InputTuner.
    """
    _keys(keys)
    return "ok"


@mcp.tool()
def brightness(direction: Literal["up", "down"], steps: int = 1) -> str:
    """Raises or lowers the TV brightness by a few steps."""
    arrow = "Right" if direction == "up" else "Left"
    _keys(TO_BRIGHTNESS + [arrow] * steps + CLOSE)
    return "ok"


@mcp.tool()
def status() -> dict:
    """TV state: power and active app or input."""
    info = _get("query/device-info")
    app = _get("query/active-app").find("app")
    return {
        "power": info.findtext("power-mode"),
        "app": app.text if app is not None else None,
    }


@mcp.tool()
def apps() -> dict:
    """Installed apps, name to id (to pass to launch)."""
    return {a.text: a.get("id") for a in _get("query/apps")}


@mcp.tool()
def launch(app_id: str) -> str:
    """Launches an app by its id (see apps)."""
    _post(f"launch/{app_id}")
    return "ok"


if __name__ == "__main__":
    mcp.run()
    
