# services/cage-firefox/default.nix
# Session cage headless dédiée au VNC : un navigateur seul, sans bureau.
#
# Deuxième voie d'accès VNC, EN PLUS du montage niri + wayvnc de
# modules/home/wayvnc. Comparaison :
#
#   niri + wayvnc (modules/home/wayvnc)   cage + wayvnc (ici)
#   ------------------------------------  ---------------------------------
#   capture le vrai bureau niri           capture une seule appli
#   exige vkms (module noyau, sortie virtuelle)  backend headless de wlroots, rien à charger
#   la sortie virtuelle prend un workspace        aucun effet sur la session locale
#   meurt si la sortie disparaît          indépendant du reste
#   démarre avec la session niri          service system, démarre au boot sans login
#
# Sert à ce genre de besoin : ouvrir un navigateur graphique sur tower à
# distance, faire un login humain (Amazon, banque...), sans dépendre d'un
# écran branché ni d'une session ouverte localement.
#
# Accès :
#   LAN : http://192.168.1.44:6081/vnc.html
#         (6081 ouvert dans profiles/tower/configuration.nix)
#   tunnel SSH : ssh -L 6081:localhost:6081 marc@tower puis http://localhost:6081/vnc.html
#
# Détails de mise au point, appris au banc d'essai :
#   - cage démarre son propre XWayland, donc une appli X11 marche aussi bien
#     qu'une appli Wayland native.
#   - la sortie headless wlroots (HEADLESS-1) n'annonce QUE 1280x720, mais
#     accepte n'importe quelle taille via --custom-mode. On est en 1920x1080.
#   - le mode doit être posé AVANT wayvnc : wayvnc fige la taille de l'écran à
#     sa connexion et ne la relit pas ensuite. D'où l'ordre imposé dans le
#     script de session et non un ExecStartPost.
#
# Sécurité : websockify écoute sur 0.0.0.0:6081, donc joignable sur le LAN sans
# mot de passe propre (ni noVNC ni wayvnc n'en ont). Ne pas publier 6081
# au-delà du LAN.
{
  pkgs,
  config,
  ...
}: let
  # Taille de l'écran virtuel de cette session.
  width = 1920;
  height = 1080;

  # noVNC + wayvnc, mêmes paquets que la session niri, dans le pin stable.
  novncPort = 6081;
  rfbPort = 5901;

  # Profil de navigateur dédié : ne touche pas au profil firefox habituel de
  # marc (deux firefox sur un même profil se disputent le lock).
  stateDir = "/var/lib/cage-firefox";

  # Script de session : cage en arrière-plan, on attend son socket, on fixe le
  # mode, puis wayvnc prend la main (exec) pour être le processus suivi par
  # systemd. wayvnc est sur loopback, seul websockify voit le LAN.
  session = pkgs.writeShellScript "cage-firefox-session" ''
    set -eu
    export XDG_RUNTIME_DIR=/run/cage-firefox
    export WAYLAND_DISPLAY=wayland-0

    # Firefox exige que le dossier de profil existe deja, sinon il sort sur une
    # boite "Profile Missing" au lieu de le creer. StateDirectory nous garantit
    # /var/lib/cage-firefox au nom de marc, il reste a creer le sous-dossier.
    mkdir -p ${stateDir}/profile

    ${pkgs.cage}/bin/cage -- ${pkgs.firefox}/bin/firefox --no-remote -profile ${stateDir}/profile &
    cage_pid=$!

    # Attendre que cage ait publié son socket avant de parler au compositeur.
    for _ in $(seq 1 100); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.1
    done

    # Ignoré si l'output n'existe pas encore, la session reste utilisable en
    # 1280x720 plutôt que de mourir.
    ${pkgs.wlr-randr}/bin/wlr-randr --output HEADLESS-1 --custom-mode ${toString width}x${toString height} || true

    exec ${pkgs.wayvnc}/bin/wayvnc -o HEADLESS-1 127.0.0.1 ${toString rfbPort}
  '';
in {
  systemd.services.cage-firefox = {
    description = "Session cage headless + firefox, exposée en VNC";
    # Service system et pas user : la session VNC doit exister même si personne
    # n'est connecté localement, contrairement à un service utilisateur (le
    # Linger de marc est à non) et contrairement à la session niri qui exige un
    # login graphique.
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = "marc";
      Group = "users";
      WorkingDirectory = stateDir;
      StateDirectory = "cage-firefox"; # crée /var/lib/cage-firefox au nom de marc
      RuntimeDirectory = "cage-firefox"; # XDG_RUNTIME_DIR de la session (0700)
      ExecStart = "${session}";
      # KillMode par défaut = control-group : cage, firefox et wayvnc tombent
      # ensemble au redémarrage ou à l'arrêt.
      Restart = "always";
      RestartSec = "3s";
    };
    environment = {
      WLR_BACKENDS = "headless"; # le backend qui crée la sortie virtuelle
      WLR_LIBINPUT_NO_DEVICES = "1"; # ne pas aspirer les périphériques physiques
      MOZ_ENABLE_WAYLAND = "1";
    };
  };

  # Client web : noVNC en HTML + pont WebSocket vers le RFB de wayvnc.
  systemd.services.novnc-cage = {
    description = "noVNC (session cage/firefox) sur le port ${toString novncPort}";
    wantedBy = ["multi-user.target"];
    after = ["cage-firefox.service"];
    requires = ["cage-firefox.service"];
    serviceConfig = {
      # DynamicUser : aucun état sur disque, tout est lu dans le store.
      DynamicUser = true;
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 0.0.0.0:${toString novncPort} localhost:${toString rfbPort}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [novncPort]; # wayvnc reste sur loopback
}
