# services/hermes/roku.nix
# Serveur MCP minimal pour piloter la TV Roku (ECP, réseau local).
# À importer depuis services/hermes/default.nix : imports = [ ./roku.nix ];
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

      # Touches pour atteindre le réglage de luminosité depuis l'entrée HDMI.
      # À relever une fois à la télécommande (touche ✱ = Info).
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
          """Appuie sur des touches de la télécommande Roku, dans l'ordre.

          Touches : Home, Back, Select, Up, Down, Left, Right, Info (✱),
          Play, Rev, Fwd, InstantReplay, VolumeUp, VolumeDown, VolumeMute,
          PowerOn, PowerOff, InputHDMI1, InputHDMI2, InputHDMI3, InputTuner.
          """
          _keys(keys)
          return "ok"


      @mcp.tool()
      def brightness(direction: Literal["up", "down"], steps: int = 1) -> str:
          """Monte ou baisse la luminosité de la TV de quelques crans."""
          arrow = "Right" if direction == "up" else "Left"
          _keys(TO_BRIGHTNESS + [arrow] * steps + CLOSE)
          return "ok"


      @mcp.tool()
      def status() -> dict:
          """État de la TV : alimentation et app ou entrée active."""
          info = _get("query/device-info")
          app = _get("query/active-app").find("app")
          return {
              "power": info.findtext("power-mode"),
              "app": app.text if app is not None else None,
          }


      @mcp.tool()
      def apps() -> dict:
          """Apps installées, nom vers id (à passer à launch)."""
          return {a.text: a.get("id") for a in _get("query/apps")}


      @mcp.tool()
      def launch(app_id: str) -> str:
          """Lance une app par son id (voir apps)."""
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
