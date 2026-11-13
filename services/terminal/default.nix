# services/terminal/default.nix
# Terminal web REEL sur terminal.marcpartensky.com (ttyd).
#
# Ce domaine servait jusqu'ici le panneau d'admin Hermes
# (services/hermes-dashboard), dont la « page terminal » n'est qu'un onglet de
# cette UI : ce n'etait donc pas un terminal. Ici l'URL ne sert QUE le terminal.
#
# Techno : ttyd (MIT, C/libwebsockets + xterm.js), deja dans nixpkgs avec son
# module NixOS `services.ttyd`. Rien a packager, un seul binaire, un vrai PTY
# par client, websockets gerees par le module.
#
# Chaine : Pangolin (terminal.marcpartensky.com, SSO)
#          -> newt (site tower)
#          -> 127.0.0.1:9122 (ttyd, --interface lo : loopback seulement)
#
# Utilisateur : `marc`, pas `hermes`. C'est le terminal de marc (son home, ses
# outils, son zellij), protege par le meme SSO Pangolin que le bureau
# noVNC/Kasm deja expose. Pour obtenir a la place le shell de l'agent (celui
# qui a le sudo nixos-rebuild NOPASSWD et l'ACL sur ~/git/nixos), changer
# `user` et le PATH de `terminalSession` ci-dessous.
#
# Persistance : l'entree de ttyd rattache une session zellij nommee au lieu de
# lancer un bash nu, donc fermer l'onglet (ou perdre le reseau mobile) ne tue
# pas le travail en cours : on se rattache a la meme session. Repli sur un
# shell de login si zellij n'est pas utilisable (pas de XDG_RUNTIME_DIR).
#
# Ne JAMAIS ouvrir 9122 au firewall : ttyd est un shell interactif.
{
  config,
  lib,
  pkgs,
  ...
}: let
  port = 9122;
  # Session zellij partagee : tous les clients (onglets, telephone) tombent
  # dans la meme session. En changer = nouveau terminal vierge.
  zellijSession = "web";

  # Entree de ttyd : zellij persistant, sinon shell de login.
  terminalSession = pkgs.writeShellApplication {
    name = "terminal-session";
    runtimeInputs = [
      pkgs.zellij
      pkgs.bashInteractive
      pkgs.coreutils
    ];
    text = ''
      # Le profil home-manager de marc n'est pas dans le PATH par defaut des
      # unites systemd : sans ca, zellij (et ses outils) est introuvable.
      export PATH="/run/current-system/sw/bin:/home/marc/.nix-profile/bin''${PATH:+:$PATH}"

      # zellij (son serveur de session) exige un XDG_RUNTIME_DIR inscriptible,
      # qui appartient a la session de marc. users.users.marc.linger = true est
      # pose dans profiles/tower (KasmVNC), donc /run/user/1000 existe meme sans
      # session graphique ; si ce n'est pas le cas on retombe sur bash.
      # (deux instructions pour satisfaire shellcheck SC2155, cf. writeShellApplication)
      runtime_dir="/run/user/$(id -u)"
      if [ -z "''${XDG_RUNTIME_DIR:-}" ] && [ -d "$runtime_dir" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
      fi

      if [ -n "''${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        exec zellij attach --create ${zellijSession}
      fi

      echo "zellij indisponible (XDG_RUNTIME_DIR absent) : shell de login simple" >&2
      exec bash -l
    '';
  };
in {
  services.ttyd = {
    enable = true;
    port = port;
    # Loopback seulement : mesure du 11/11/2026, `ttyd --interface lo` binde
    # 127.0.0.1:9122 (et non 0.0.0.0). Seul newt joint le port.
    interface = "lo";
    user = "marc";
    # -W : le client ecrit dans le PTY (c'est tout l'interet d'un terminal).
    writeable = true;
    maxClients = 4;
    entrypoint = [ (lib.getExe terminalSession)];
    clientOptions = {
      fontSize = "14";
      # Theme par defaut de marc (Catppuccin Mocha), accent Lavender.
      theme = builtins.toJSON {
        background = "#1e1e2e";
        foreground = "#cdd6f4";
        cursor = "#b4befe";
        cursorAccent = "#1e1e2e";
        selectionBackground = "#585b70";
        black = "#45475a";
        red = "#f38ba8";
        green = "#a6e3a1";
        yellow = "#f9e2af";
        blue = "#89b4fa";
        magenta = "#cba6f7";
        cyan = "#94e2d5";
        white = "#bac2de";
        brightBlack = "#585b70";
        brightRed = "#f38ba8";
        brightGreen = "#a6e3a1";
        brightYellow = "#f9e2af";
        brightBlue = "#89b4fa";
        brightMagenta = "#cba6f7";
        brightCyan = "#94e2d5";
        brightWhite = "#a6adc8";
      };
    };
    # `checkOrigin` reste desactive (defaut) : active, ttyd compare l'en-tete
    # Origin au Host recu, et Pangolin ne garantit pas de transmettre le Host
    # public (la ressource du dashboard est justement passee par un nginx local
    # pour reecrire le Host). Le gate, ici, c'est le SSO Pangolin.
  };

  # L'unite tourne dans le home de marc avec un PATH complet : le shell obtenu
  # est celui qu'il aurait en SSH (git, just, nixos-rebuild...).
  systemd.services.ttyd = {
    environment.HOME = "/home/marc";
    serviceConfig.WorkingDirectory = "/home/marc";
    # Un rebuild ne doit pas couper la session en cours (meme choix que
    # services/hermes-webui) : la config s'applique au prochain demarrage.
    restartIfChanged = false;
  };

  # Exposition publique : terminal.marcpartensky.com -> 127.0.0.1:9122, SSO
  # Pangolin (Zitadel) comme les autres UIs.
  #
  # CLE `hermes-terminal` VOLONTAIRE : c'est le niceId (identifiant) de la
  # ressource Pangolin qui porte DEJA terminal.marcpartensky.com (resourceId 28,
  # cible 9121 = panneau d'admin Hermes). Un blueprint apparie par cle et ne
  # supprime JAMAIS une entree disparue : renommer la cle aurait cree une
  # seconde ressource sur le meme domaine (conflit) en laissant l'ancienne
  # orpheline sur ce domaine. Garder la cle met donc la ressource en place a
  # jour (nom + cible 9122) et le panneau d'admin part sur une ressource neuve,
  # `hermes-dashboard` dans services/hermes-dashboard (verifie le 11/11/2026 :
  # resourceId 28, niceId hermes-terminal, skipToIdpId null).
  #
  # NB : `auth.sso-enabled` gate la ressource, mais le blueprint ne porte pas de
  # champ pour aller directement a l'IdP : `resources.skipToIdpId = 1` est pose
  # en base Pangolin pour les autres ressources (navidrome, aonsoku...), sinon
  # la page de login interne du proxy s'affiche avant Zitadel. A reposer si la
  # ressource est recreee (uuid qui change).
  services.newt.blueprint.proxy-resources.hermes-terminal = {
    name = "terminal";
    protocol = "http";
    full-domain = "terminal.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        # ttyd repond 200 text/html sur "/" (mesure du 11/11/2026).
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
          path = "/";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # Garde-fou : 9122 est un shell interactif.
  assertions = [
    {
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "terminal : le port ${toString port} (ttyd = shell) ne doit pas etre ouvert au firewall.";
    }
  ];
}
