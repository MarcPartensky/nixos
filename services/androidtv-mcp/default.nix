# services/androidtv-mcp/default.nix
#
# Serveur MCP pour la TV TCL du salon (Android TV 11, plateforme R851T02).
# Protocole Android TV Remote v2, le même que l'app Google TV :
# pas de mode développeur, pas d'ADB, juste un appairage par code affiché sur la TV.
#
# À importer uniquement sur un host qui est sur le même réseau que la TV (tower).
{pkgs, ...}: let
  # IP de la TV : Paramètres > About > Status. Fixe-la en bail DHCP statique sur le routeur.
  tvHost = "192.168.1.XX";
  port = 8765;
  stateDir = "/var/lib/androidtv-mcp";

  server =
    pkgs.writers.writePython3Bin "androidtv-mcp-server" {
      libraries = with pkgs.python3Packages; [mcp androidtvremote2];
      flakeIgnore = ["E501"];
    } ''
      """MCP server for an Android TV, over the Android TV Remote v2 protocol."""

      import asyncio
      import logging
      import os
      import sys
      from pathlib import Path
      from typing import Literal

      from androidtvremote2 import (
          AndroidTVRemote,
          CannotConnect,
          ConnectionClosed,
          InvalidAuth,
      )
      from mcp.server.fastmcp import FastMCP

      HOST = os.environ["ATV_HOST"]
      STATE = Path(os.environ.get("ATV_STATE_DIR", "."))
      CERT = str(STATE / "cert.pem")
      KEY = str(STATE / "key.pem")
      NAME = os.environ.get("ATV_CLIENT_NAME", "Hermes")

      mcp = FastMCP(
          "tv",
          instructions="Controls the living room Android TV (TCL).",
          host="127.0.0.1",
          port=int(os.environ.get("ATV_PORT", "8765")),
      )

      _remote = None
      _up = False
      _lock = asyncio.Lock()


      def _set_up(value):
          global _up
          _up = value


      async def tv():
          """Return a connected remote, connecting on demand."""
          global _remote, _up
          async with _lock:
              if _remote is None:
                  _remote = AndroidTVRemote(NAME, CERT, KEY, HOST)
                  _remote.add_is_available_updated_callback(_set_up)
              if not _up:
                  _remote.disconnect()
                  try:
                      await asyncio.wait_for(_remote.async_connect(), 10)
                  except InvalidAuth:
                      raise RuntimeError(
                          "TV not paired: run 'androidtv-mcp pair' on the host"
                      )
                  except (CannotConnect, ConnectionClosed, OSError,
                          asyncio.TimeoutError) as exc:
                      raise RuntimeError(
                          f"TV unreachable at {HOST} (off or other network): {exc}"
                      )
                  _up = True
                  _remote.keep_reconnecting()
                  for _ in range(20):
                      if _remote.is_on is not None:
                          break
                      await asyncio.sleep(0.05)
          return _remote


      @mcp.tool()
      async def tv_status() -> dict:
          """Power state, foreground app (package id), volume and model."""
          r = await tv()
          return {
              "on": r.is_on,
              "app": r.current_app,
              "volume": r.volume_info,
              "device": r.device_info,
          }


      @mcp.tool()
      async def tv_power(state: Literal["on", "off", "toggle"]) -> str:
          """Turn the TV on, off, or toggle it."""
          r = await tv()
          if state == "toggle" or (state == "on") != bool(r.is_on):
              r.send_key_command("POWER")
              return f"power {state}: done"
          return f"power {state}: already {state}"


      @mcp.tool()
      async def tv_keys(keys: list[str], delay_ms: int = 150) -> str:
          """Press remote keys in order.

          Common names: DPAD_UP, DPAD_DOWN, DPAD_LEFT, DPAD_RIGHT,
          DPAD_CENTER (OK), BACK, HOME, MENU, SETTINGS, SEARCH,
          MEDIA_PLAY_PAUSE, MEDIA_STOP, MEDIA_NEXT, MEDIA_PREVIOUS,
          MEDIA_FAST_FORWARD, MEDIA_REWIND, VOLUME_UP, VOLUME_DOWN,
          VOLUME_MUTE, CAPTIONS, TV_INPUT, TV_INPUT_HDMI_1 to TV_INPUT_HDMI_4.
          """
          r = await tv()
          for key in keys:
              try:
                  r.send_key_command(key.upper())
              except ValueError:
                  raise RuntimeError(f"unknown key: {key}")
              await asyncio.sleep(delay_ms / 1000)
          return f"sent {len(keys)} key(s)"


      @mcp.tool()
      async def tv_launch(app: str) -> str:
          """Open an app by package id, or open a deep link URL.

          Package ids: com.netflix.ninja, com.google.android.youtube.tv,
          com.amazon.amazonvideo.livingroom, com.disney.disneyplus,
          com.tubitv, com.spotify.tv.android, com.plexapp.android.
          Deep links: https://www.youtube.com/watch?v=VIDEO_ID,
          https://www.netflix.com/title/TITLE_ID.
          """
          r = await tv()
          r.send_launch_app_command(app)
          return f"launching {app}"


      @mcp.tool()
      async def tv_text(text: str) -> str:
          """Type text into the focused field (e.g. a search box)."""
          r = await tv()
          r.send_text(text)
          return "text sent"


      @mcp.tool()
      async def tv_volume(level: int) -> str:
          """Set the volume to an absolute level (tv_status gives the max)."""
          r = await tv()
          info = r.volume_info
          if not info:
              raise RuntimeError("volume unknown, use tv_keys VOLUME_UP/DOWN")
          current = info["level"]
          target = max(0, min(level, info["max"]))
          key = "VOLUME_UP" if target > current else "VOLUME_DOWN"
          for _ in range(abs(target - current)):
              r.send_key_command(key)
              await asyncio.sleep(0.1)
          return f"volume {current} -> {target}"


      async def pair():
          """Interactive pairing: the TV shows a code, type it here."""
          loop = asyncio.get_running_loop()
          r = AndroidTVRemote(NAME, CERT, KEY, HOST)
          await r.async_generate_cert_if_missing()
          try:
              name, mac = await r.async_get_name_and_mac()
          except CannotConnect:
              sys.exit(f"TV unreachable at {HOST}")
          print(f"Pairing with {name} ({mac}) at {HOST}")
          await r.async_start_pairing()
          while True:
              code = await loop.run_in_executor(None, input, "Code on the TV: ")
              try:
                  await r.async_finish_pairing(code.strip())
              except InvalidAuth:
                  print("Wrong code, try again.")
                  continue
              except ConnectionClosed:
                  sys.exit("Pairing cancelled on the TV, run pair again.")
              print("Paired.")
              return


      def main():
          logging.basicConfig(level=logging.INFO, stream=sys.stderr)
          cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
          if cmd == "pair":
              asyncio.run(pair())
          elif cmd == "serve":
              mcp.run(transport="streamable-http")
          else:
              sys.exit("usage: androidtv-mcp [serve|pair]")


      if __name__ == "__main__":
          main()
    '';

  # Wrapper : même config pour le service et pour l'appairage manuel
  cli = pkgs.writeShellScriptBin "androidtv-mcp" ''
    export ATV_HOST=${tvHost}
    export ATV_PORT=${toString port}
    export ATV_STATE_DIR=${stateDir}
    exec ${server}/bin/androidtv-mcp-server "$@"
  '';
in {
  users.users.androidtv-mcp = {
    isSystemUser = true;
    group = "androidtv-mcp";
    home = stateDir;
  };
  users.groups.androidtv-mcp = {};

  environment.systemPackages = [cli];

  systemd.services.androidtv-mcp = {
    description = "MCP server for the living room Android TV";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];
    serviceConfig = {
      ExecStart = "${cli}/bin/androidtv-mcp serve";
      User = "androidtv-mcp";
      Group = "androidtv-mcp";
      StateDirectory = "androidtv-mcp"; # certificat d'appairage
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = 5;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
    };
  };

  # Branché sur le Hermes local, écoute sur 127.0.0.1 uniquement
  services.hermes-agent.mcpServers.tv.url = "http://127.0.0.1:${toString port}/mcp";
}
