# modules/home/wayvnc/default.nix
# VNC server on the niri session + noVNC web client.
#
# wayvnc is launched by niri (spawn-at-startup) and NOT by a systemd unit:
# a user service does not have WAYLAND_DISPLAY in its environment, so wayvnc
# did not find the compositor and exited immediately. Launched by the
# compositor, the environment is guaranteed. Trade-off: no automatic
# restart, if wayvnc dies you have to restart the session or the process.
#
# Access:
#   LAN           : http://192.168.1.44:6080/vnc.html
#                   (port 6080 opened in profiles/tower/configuration.nix)
#   Pangolin SSO  : https://vnc.marcpartensky.com/vnc.html
#                   (HTTP resource declared in services/newt/default.nix)
#   tunnel SSH    : ssh -L 6080:localhost:6080 marc@tower then http://localhost:6080/vnc.html
#   native client : vnc://localhost:5900 via the SSH tunnel (wayvnc stays loopback)
#
# Security: websockify listens on 0.0.0.0:6080, so on the LAN with no
# password of its own (neither noVNC nor wayvnc has one). Do not publish 6080 beyond the LAN.
# On the public name, authentication is Pangolin's (SSO).
{
  pkgs,
  ...
}: let
  # Resolution of the vkms virtual screen (output "Virtual-1", cf. boot.kernelModules
  # in profiles/tower/configuration.nix). 1920x1080 = the logical size of
  # marc's Beyond TV (3840x2160 at @2x). VKMS also exposes 2560x1600, 4096x2160 and
  # custom via `niri msg output Virtual-1 custom-mode <W> <H> <Hz>`.
  virtualWidth = 1920;
  virtualHeight = 1080;
in {
  home.packages = [pkgs.wayvnc];

  # Absolute path rather than "wayvnc": independent of the session PATH.
  programs.niri.settings.spawn-at-startup = [
    {argv = ["${pkgs.wayvnc}/bin/wayvnc"];}
  ];

  # Mode of the virtual screen. Niri re-reads its config live, so a `just home`
  # is enough to change the resolution, no need to re-log (wayvnc follows, it
  # detects the output change).
  programs.niri.settings.outputs."Virtual-1".mode = {
    width = virtualWidth;
    height = virtualHeight;
    refresh = 60.0;
  };

  # noVNC web client: serves the HTML interface and bridges WebSocket -> RFB
  # (wayvnc speaks RFB on 5900, noVNC speaks WebSocket; websockify translates).
  # No dependency on Wayland, so a systemd unit is fine here.
  systemd.user.services.novnc = {
    Unit = {
      Description = "noVNC web client (WebSocket bridge -> wayvnc:5900)";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      # 0.0.0.0: reachable from the LAN (port opened in profiles/tower) AND
      # from newt locally, which targets 127.0.0.1:6080. wayvnc itself stays on
      # loopback: only one port open to the outside.
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 0.0.0.0:6080 localhost:5900";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
