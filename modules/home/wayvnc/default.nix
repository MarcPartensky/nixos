# modules/home/wayvnc/default.nix
# Démarre wayvnc automatiquement avec la session niri (via graphical-session.target,
# le même point d'accroche que ironbar : niri.service upstream fait
# BindsTo=graphical-session.target + Before=graphical-session.target, donc démarrer
# niri.service active aussi graphical-session.target, ce qui déclenche ce service).
#
# Sécurité : tout écoute uniquement sur 127.0.0.1 (pas d'exposition LAN, pas
# d'auth nécessaire). Accès distant :
#   ssh -L 6080:localhost:6080 -L 5900:localhost:5900 marc@tower
#   client web noVNC : http://localhost:6080/vnc.html
#   ou client VNC natif : vnc://localhost:5900 (macOS : `open vnc://localhost:5900`)
{pkgs, ...}: {
  home.packages = [pkgs.wayvnc];

  systemd.user.services.wayvnc = {
    Unit = {
      Description = "wayvnc VNC server (accès distant à la session niri)";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${pkgs.wayvnc}/bin/wayvnc";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };

  # Client web noVNC : sert l'interface HTML et fait le pont WebSocket -> RFB
  # (wayvnc 0.10.0 parle RFB sur 5900, noVNC parle WebSocket ; websockify traduit).
  # Bindé sur 127.0.0.1 uniquement, comme wayvnc : accès par tunnel SSH.
  systemd.user.services.novnc = {
    Unit = {
      Description = "noVNC web client (pont WebSocket -> wayvnc:5900)";
      After = ["graphical-session.target" "wayvnc.service"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 127.0.0.1:6080 localhost:5900";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
