# modules/home/wayvnc/default.nix
# Serveur VNC sur la session niri + client web noVNC.
#
# wayvnc est lancé par niri (spawn-at-startup) et NON par une unité systemd :
# un service utilisateur n'a pas WAYLAND_DISPLAY dans son environnement, wayvnc
# ne trouvait donc pas le compositeur et sortait aussitôt. Lancé par le
# compositeur, l'environnement est garanti. Contrepartie : pas de redémarrage
# automatique, si wayvnc meurt il faut relancer la session ou le processus.
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
{
  pkgs,
  ...
}: let
  # Résolution de l'écran virtuel vkms (sortie "Virtual-1", cf. boot.kernelModules
  # dans profiles/tower/configuration.nix). 1920x1080 = la taille logique du
  # Beyond TV de marc (3840x2160 en @2x). VKMS expose aussi 2560x1600, 4096x2160 et
  # du custom via `niri msg output Virtual-1 custom-mode <W> <H> <Hz>`.
  virtualWidth = 1920;
  virtualHeight = 1080;
in {
  home.packages = [pkgs.wayvnc];

  # Chemin absolu plutôt que "wayvnc" : indépendant du PATH de la session.
  programs.niri.settings.spawn-at-startup = [
    {argv = ["${pkgs.wayvnc}/bin/wayvnc"];}
  ];

  # Mode de l'écran virtuel. Niri relit sa config à chaud, donc un `just home`
  # suffit à changer la résolution, pas besoin de relogger (wayvnc suit, il
  # détecte le changement de sortie).
  programs.niri.settings.outputs."Virtual-1".mode = {
    width = virtualWidth;
    height = virtualHeight;
    refresh = 60.0;
  };

  # Client web noVNC : sert l'interface HTML et fait le pont WebSocket -> RFB
  # (wayvnc parle RFB sur 5900, noVNC parle WebSocket ; websockify traduit).
  # Pas de dépendance à Wayland, donc une unité systemd convient ici.
  systemd.user.services.novnc = {
    Unit = {
      Description = "noVNC web client (pont WebSocket -> wayvnc:5900)";
      After = ["graphical-session.target"];
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
