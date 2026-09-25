# modules/home/wayvnc/default.nix
# Démarre wayvnc automatiquement avec la session niri (via graphical-session.target,
# le même point d'accroche que ironbar : niri.service upstream fait
# BindsTo=graphical-session.target + Before=graphical-session.target, donc démarrer
# niri.service active aussi graphical-session.target, ce qui déclenche ce service).
#
# Accès :
#   LAN           : http://192.168.1.44:6080/vnc.html
#                   (port 6080 ouvert dans profiles/tower/configuration.nix)
#   Pangolin SSO  : https://vnc.marcpartensky.com/vnc.html
#                   (ressource HTTP déclarée dans services/newt/default.nix)
#   tunnel SSH    : ssh -L 6080:localhost:6080 marc@tower puis http://localhost:6080/vnc.html
#   client natif  : vnc://localhost:5900 via le tunnel SSH (wayvnc reste loopback)
#
# Sécurité : websockify écoute sur 0.0.0.0:6080, donc sur le LAN sans aucun mot de
# passe propre (ni noVNC ni wayvnc n'en ont). Ne pas publier 6080 au-delà du LAN.
# Sur le nom public, l'authentification est celle de Pangolin (SSO).
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
      # 0.0.0.0: joignable depuis le LAN (port ouvert dans profiles/tower) ET
      # depuis newt en local, qui cible 127.0.0.1:6080. wayvnc, lui, reste sur
      # loopback : un seul port ouvert vers l'extérieur.
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 0.0.0.0:6080 localhost:5900";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
