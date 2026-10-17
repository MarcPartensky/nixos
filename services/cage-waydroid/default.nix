# services/cage-waydroid/default.nix
# Waydroid (Android LineageOS) dans un compositeur cage HEADLESS, expose en VNC
# standard (wayvnc) sur le LAN, protege par un mot de passe. Patron de
# services/cage-firefox.
#
# POURQUOI root (pas de User=) : `waydroid session start` appelle
# waydroid-net.sh qui cree le bridge waydroid0 (CAP_NET_ADMIN). En non-root ca
# sort en « Operation not permitted ». De plus la session waydroid est un
# SINGLETON GLOBAL (une 2e session, meme d'un autre utilisateur, sort en
# « Already tracking a session ») : c'est ce service qui la detient.
#
# POURQUOI cage headless (et pas weston) : waydroid exige un compositeur Wayland.
# En headless il n'y a AUCUNE contrainte de compositeur hote (pas de X11, pas de
# visual 32 bits) : cage suffit. Mode isole et robuste.
#
# PREREQUIS (une fois, root) : `sudo waydroid init -s GAPPS` (images).
#
# ACCES (LAN uniquement) :
#   Finder > Aller > Se connecter au serveur... > vnc://192.168.1.44:5902
#   (ou `vncviewer 192.168.1.44:5902` avec TigerVNC / RealVNC Viewer)
#   mot de passe : android
#   Auth DES (VncAuth) -> macOS Screen Sharing fonctionne.
{ pkgs, ... }:
let
  # Portrait, format telephone.
  width = 1080;
  height = 1920;

  rfbPort = 5902;
  # Port loopback du pont noVNC (cible du connecteur newt/Pangolin). PAS ouvert
  # au LAN : seul newt le joint, et il tourne sur tower (127.0.0.1).
  novncPort = 6082;
  # Mot de passe simple (DES = 8 caracteres max, le reste est ignore), LAN
  # uniquement. Pour le sortir du store Nix, le mettre dans secrets/ (sops).
  vncPassword = "android";

  # cage en arriere-plan avec l'UI Waydroid, puis wayvnc devient le process
  # suivi par systemd (comme cage-firefox).
  session = pkgs.writeShellScript "cage-waydroid-session" ''
    set -eu
    export XDG_RUNTIME_DIR=/run/cage-waydroid
    export HOME=/var/lib/cage-waydroid
    export WAYLAND_DISPLAY=wayland-0
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1

    # waydroid genere dans config_session des lxc.mount.entry SANS 'optional'
    # pour le socket pulse et le dossier data : si ces chemins n'existent pas,
    # LXC refuse de demarrer le conteneur (« container failed to start »).
    # On fournit un vrai socket UNIX qui accepte puis referme (l'audio n'est pas
    # route, mais le montage est valide et ne bloque pas le boot).
    mkdir -p "$XDG_RUNTIME_DIR/pulse"
    ${pkgs.python3}/bin/python3 -c '
import os, socket, sys
p = sys.argv[1]
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind(p)
s.listen(16)
while True:
    try:
        c, _ = s.accept()
        c.close()
    except OSError:
        pass
' "$XDG_RUNTIME_DIR/pulse/native" &
    mkdir -p "$HOME/.local/share/waydroid/data"

    # `waydroid show-full-ui` demarre la session si besoin puis ouvre l'UI plein
    # ecran, que cage affiche.
    ${pkgs.cage}/bin/cage -- ${pkgs.waydroid}/bin/waydroid show-full-ui &
    cage_pid=$!

    # Attendre le socket du compositeur avant de parler a l'output.
    for _ in $(seq 1 150); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.2
    done

    # La sortie headless wlroots n'annonce que 1280x720 : on force le portrait.
    ${pkgs.wlr-randr}/bin/wlr-randr --output HEADLESS-1 --custom-mode ${toString width}x${toString height} || true

    # wayvnc : auth DES (VncAuth classique, type 2). C'est le SEUL mode que
    # macOS Screen Sharing sait negocier (wayvnc README : « This option exists
    # solely for compatibility with VNC clients that support DES but do not
    # support the absence of authentication, such as macOS Screen Sharing »).
    # relax_encryption + allow_broken_crypto = pas de chiffrement (mot de passe
    # DES en clair) : acceptable sur le LAN, PAS au-dela. Ecoute sur toutes les
    # interfaces, le firewall fait office de filtre LAN.
    vdir="$HOME/wayvnc"
    mkdir -p "$vdir"
    cat > "$vdir/config" <<EOF
address=0.0.0.0
port=${toString rfbPort}
enable_auth=true
password=${vncPassword}
relax_encryption=true
allow_broken_crypto=true
EOF

    exec ${pkgs.wayvnc}/bin/wayvnc -C "$vdir/config"
  '';
in {
  systemd.services.cage-waydroid = {
    description = "Waydroid (Android) dans cage headless, expose en VNC (LAN, mot de passe)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "waydroid-container.service" ];
    requires = [ "waydroid-container.service" ];
    serviceConfig = {
      # ROOT volontaire : waydroid-net.sh a besoin de CAP_NET_ADMIN.
      RuntimeDirectory = "cage-waydroid";
      StateDirectory = "cage-waydroid"; # /var/lib/cage-waydroid = HOME persistant
      ExecStart = "${session}";
      # KillMode par defaut = control-group : cage, waydroid et wayvnc tombent
      # ensemble au redemarrage.
      Restart = "always";
      RestartSec = "5s";
    };
    # HOME requis par wayvnc (« Failed to load config. Success » sans lui) et
    # pour que les cles wayvnc + le dossier data de waydroid persistent.
    environment.HOME = "/var/lib/cage-waydroid";
  };

  # Client web noVNC : pont WebSocket -> RFB de wayvnc, sur loopback.
  # Cible du connecteur newt (Pangolin) : rien n'est ouvert au LAN par ce port.
  # noVNC gere lui-meme l'auth VncAuth(DES) de wayvnc (il demande le mot de
  # passe), donc le pont websockify reste en clair (pas de --ssl-target).
  systemd.services.novnc-waydroid = {
    description = "noVNC (pont WebSocket -> wayvnc:${toString rfbPort}) pour Pangolin";
    wantedBy = [ "multi-user.target" ];
    after = [ "cage-waydroid.service" ];
    requires = [ "cage-waydroid.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 127.0.0.1:${toString novncPort} localhost:${toString rfbPort}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ rfbPort ];
}