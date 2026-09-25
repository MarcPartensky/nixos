# modules/home/wayvnc/default.nix
# Démarre wayvnc automatiquement avec la session niri (via graphical-session.target,
# le même point d'accroche que ironbar : niri.service upstream fait
# BindsTo=graphical-session.target + Before=graphical-session.target, donc démarrer
# niri.service active aussi graphical-session.target, ce qui déclenche ce service).
#
# Sécurité : aucune option = wayvnc écoute uniquement sur 127.0.0.1:5900 (pas
# d'exposition LAN, pas d'auth nécessaire). Accès distant :
#   ssh -L 5900:localhost:5900 marc@tower
#   puis un client VNC sur vnc://localhost:5900 (macOS : `open vnc://localhost:5900`)
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
}
