# services/hermes/roku.nix
# Minimal MCP server to drive the Roku TV (ECP, local network).
# To import from services/hermes/default.nix: imports = [ ./roku.nix ];
{pkgs, ...}: let
  roku-mcp =
    pkgs.writers.writePython3Bin "roku-mcp" {
      libraries = [pkgs.python3Packages.mcp];
    } ''
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
      # To be recorded once on the remote (the * key = Info).
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
          """Press keys on the Roku remote, in order.

          Keys: Home, Back, Select, Up, Down, Left, Right, Info (*),
          Play, Rev, Fwd, InstantReplay, VolumeUp, VolumeDown, VolumeMute,
          PowerOn, PowerOff, InputHDMI1, InputHDMI2, InputHDMI3, InputTuner.
          """
          _keys(keys)
          return "ok"


      @mcp.tool()
      def brightness(direction: Literal["up", "down"], steps: int = 1) -> str:
          """Raise or lower the TV brightness by a few steps."""
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
          """Launch an app by its id (see apps)."""
          _post(f"launch/{app_id}")
          return "ok"


      if __name__ == "__main__":
          mcp.run()
    '';
in {
  services.hermes-agent.mcpServers.roku = {
    command = "${roku-mcp}/bin/roku-mcp";
    env.ROKU_URL = "http://192.168.1.167:8060";
  };
}
