{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.kasmvnc;

  # L'ancien code faisait `elemAt (builtins.split "x" cfg.geometry) 0/1` :
  # builtins.split renvoie [prefixe, groupes, suffixe], donc l'index 0 donne bien
  # "1920" mais l'index 1 est la LISTE des groupes de capture, pas "1080". Le
  # height partait donc vide dans le YAML. splitString donne exactement les deux
  # morceaux attendus.
  geometryParts = splitString "x" cfg.geometry;
  width = elemAt geometryParts 0;
  height = elemAt geometryParts 1;

  # perl + les modules CPAN que le wrapper kasmvncserver importe et que le deb ne
  # fournit pas (le deb ne livre que ses propres modules KasmVNC::*).
  perlLib = pkgs.perl.withPackages (ps: with ps; [
    Switch
    ListMoreUtils
    TryTiny
    DateTime
    DateTimeTimeZone
    DateTimeLocale
    YAMLTiny
    HashMergeSimple
  ]);

  # Fetch KasmVNC from GitHub Releases (not in nixpkgs)
  kasmvncPackage = pkgs.stdenv.mkDerivation rec {
    pname = "kasmvnc";
    version = "1.5.0";

    src = pkgs.fetchurl {
      url = "https://github.com/kasmtech/KasmVNC/releases/download/v${version}/kasmvncserver_noble_${version}_amd64.deb";
      sha256 = "sha256-9Zn+AuIXW5gXthZfdKXSvr3HMRjd6Rgbo0EJY77Xrh4=";
    };

    # kasmvncserver et kasmvncconfig sont des SCRIPTS PERL, pas des ELF : l'ancien
    # garde `if file .../kasmvncserver | grep -q ELF` testait le script, donc etait
    # toujours FAUX et aucun binaire n'etait patche -> kasmvncpasswd sortait en
    # « error while loading shared libraries: libcrypt.so.1 ». autoPatchelfHook
    # patche tous les ELF du deb et resout les libs depuis buildInputs.
    nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook pkgs.patchelf pkgs.perl pkgs.makeWrapper ];
    buildInputs = [
      # libxcrypt-legacy et PAS libxcrypt : le .deb demande libcrypt.so.1 (soname
      # Debian) alors que pkgs.libxcrypt ne fournit que libcrypt.so.2. C'est
      # exactement l'erreur « libcrypt.so.1: cannot open shared object file ».
      pkgs.libxcrypt-legacy pkgs.glibc pkgs.gcc pkgs.libx11 pkgs.libxcb pkgs.libxkbcommon
      pkgs.wayland pkgs.libva pkgs.libdrm pkgs.mesa pkgs.libunwind pkgs.pixman
      pkgs.freetype pkgs.systemd pkgs.libxshmfence pkgs.libgbm
      # noms non-deprecies (pkgs.xorg.* emet un warning d'evaluation)
      pkgs.libxfont_2 pkgs.libxau pkgs.libxdmcp pkgs.libxtst
      pkgs.libxrandr pkgs.libxcursor
      pkgs.openssl pkgs.zlib pkgs.libjpeg_turbo pkgs.libpng pkgs.libwebp
    ];

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      dpkg -x $src $out
      # The deb extracts to root/usr/..., so move to correct location
      if [ -d $out/root ]; then
        mv $out/root/* $out/
        rmdir $out/root
      fi
      # TOUS les binaires dans $out/bin : kasmvncserver (perl) localise Xkasmvnc
      # dans le dossier de $0 (DetectBinariesDir), donc les symlinks doivent etre
      # cote a cote (systemPackages les expose ensuite dans sw/bin).
      mkdir -p $out/bin
      for b in kasmvncserver kasmvncpasswd kasmvncconfig kasmxproxy Xkasmvnc; do
        ln -sf $out/usr/bin/$b $out/bin/$b
      done
      # Le wrapper perl cherche LITTERALEMENT $exedir/Xvnc et $exedir/vncpasswd
      # (lignes 493-508) alors que le deb ne livre que Xkasmvnc / kasmvncpasswd :
      # sans ces deux alias il meurt sur « couldn't find ".../bin/Xvnc" ».
      ln -sf $out/usr/bin/Xkasmvnc $out/bin/Xvnc
      ln -sf $out/usr/bin/kasmvncpasswd $out/bin/vncpasswd
      # kasmvncserver/kasmvncconfig ont un shebang Debian #!/usr/bin/perl qui
      # n'existe pas sur NixOS (« No such file or directory » a l'execution) : le
      # fixupPhase de stdenv ne patche pas $out/usr/bin, donc explicitement ici.
      patchShebangs $out/usr/bin
      # Le wrapper charge ses valeurs par defaut depuis
      # /usr/share/kasmvnc/kasmvnc_defaults.yaml (chemin Debian absent sur NixOS,
      # donc les defauts n'etaient jamais lus). On reecrit vers le store.
      substituteInPlace $out/usr/bin/kasmvncserver \
        --replace-fail "/usr/share/kasmvnc/" "$out/usr/share/kasmvnc/"
      # Le wrapper calcule le selecteur de bureau via LocalSelectDePath()
      # (« $exedir/../builder/startup/deb/select-de.sh », arborescence du repo
      # KasmVNC) alors que le deb livre le fichier dans usr/lib/kasmvncserver/ :
      # sans cet alias la session sort en status=2 INVALIDARGUMENT avant Xvnc.
      mkdir -p $out/builder/startup/deb
      cp $out/usr/lib/kasmvncserver/select-de.sh $out/builder/startup/deb/select-de.sh
      runHook postInstall
    '';

    # Le wrapper perl doit etre autonome : PERL5LIB (ses propres modules + les
    # modules CPAN absents du deb) et le PATH (xauth, xkbcomp) sont cuits dans un
    # wrapper, pour qu'on n'ait plus besoin d'exporter quoi que ce soit avant de
    # lancer kasmvncserver (ni dans le shell, ni dans l'unite systemd).
    postFixup = ''
      wrapProgram $out/bin/kasmvncserver \
        --prefix PERL5LIB : "${perlLib}/lib/perl5/site_perl:$out/usr/share/perl5" \
        --prefix PATH : "${lib.makeBinPath [ pkgs.xauth pkgs.xkbcomp pkgs.xrandr pkgs.procps pkgs.inetutils pkgs.which pkgs.util-linux ]}"
    '';

    # Le wrapper perl charge les modules KasmVNC::* (livres dans
    # usr/share/perl5) et quelques modules CPAN absents du deb : PERL5LIB est
    # pose par le module (services.kasmvnc.environment), pas ici.
    passthru = {
      # Liste exacte des modules absents du deb, obtenue en executant le wrapper :
      # kasmvncserver importe YAML::Tiny (KasmVNC/Config.pm) et
      # Hash::Merge::Simple en plus des modules DateTime/Switch/List::MoreUtils.
      perlModules = with pkgs.perlPackages; [
        Switch
        ListMoreUtils
        TryTiny
        DateTime
        DateTimeTimeZone
        DateTimeLocale
        YAMLTiny
        HashMergeSimple
      ];
    };
  };

  # Session de bureau lancee par xstartup (X11 : kasmvncserver 1.5.0 n'a pas de
  # mode wayland). startlxqt herite du bus de session fourni par l'unite systemd.
  # PATH : l'unite fixe un `path` court (xauth, xkbcomp, hostname), ce qui
  # remplace le PATH par defaut de systemd et fait disparaitre le profil systeme.
  # Or startlxqt exec `lxqt-session` par son nom, d'ou « exec: lxqt-session: not
  # found » puis la fin immediate de la session (et l'arret de Xvnc). On remet
  # donc le profil systeme en tete : c'est la que vivent les paquets LXQt de marc
  # (lxqt-session, lxqt-panel, pcmanfm-qt, lxqt-runner).
  xstartup = pkgs.writeShellScript "kasmvnc-xstartup" (
    if cfg.desktop == "custom" then cfg.customCommand
    else if cfg.desktop == "xfce" then "exec ${pkgs.xfce.xfce4-session}/bin/xfce4-session"
    else ''
      export PATH="/run/current-system/sw/bin:${pkgs.lxqt.lxqt-session}/bin:$PATH"
      export XDG_SESSION_TYPE=x11
      export QT_QPA_PLATFORM=xcb
      export GDK_BACKEND=x11
      exec ${pkgs.lxqt.lxqt-session}/bin/startlxqt
    ''
  );

  # LXQt + kwin_wayland packages
  lxqtPkgs = with pkgs; [
    lxqt.lxqt-session
    lxqt.lxqt-panel
    lxqt.lxqt-runner
    lxqt.lxqt-notificationd
    lxqt.lxqt-globalkeys
    lxqt.lxqt-powermanagement
    lxqt.lxqt-config
    lxqt.lxqt-about
    lxqt.lxqt-admin
    lxqt.lxqt-sudo
    lxqt.lxqt-openssh-askpass
    lxqt.lxqt-policykit
    kdePackages.kwin
    wayland
    xwayland
    qt6.qtwayland
    kdePackages.breeze
    kdePackages.breeze-icons
    kdePackages.konsole
    pcmanfm-qt
  ];

  # Generate kasmvnc.yaml, au schema REEL de KasmVNC 1.5.0. L'ancien fichier
  # imbriquait network/desktop/encoding/gpu/advanced sous un bloc `server:` qui
  # n'existe pas a ce niveau : kasmvncserver repondait
  #   « Unsupported config keys found: server.desktop.allow_resize, ... »
  # et ignorait donc TOUTE la config (resolution, port, headers, mot de passe).
  # Les cles de premier niveau sont : network, desktop, encoding, security,
  # server (http/advanced/auto_shutdown), user_session, runtime_configuration.
  # Reference : usr/share/kasmvnc/kasmvnc_defaults.yaml et etc/kasmvnc/kasmvnc.yaml
  # livres dans le .deb.
  generateConfig = ''
    network:
      # Valeurs acceptees : http | vnc (verifie par kasmvncserver :
      # « network.protocol 'https': must be one of [http, vnc] »). Le TLS web
      # vient de network.ssl.require_ssl, pas du protocole.
      protocol: http
      interface: "${cfg.bindAddress}"
      # KasmVNC 1.5.0 n'a PAS de network.port : le port web est websocket_port.
      websocket_port: ${toString cfg.port}
      use_ipv4: true
      use_ipv6: true
      ssl:
        pem_certificate: "${cfg.tls.certFile}"
        pem_key: "${cfg.tls.keyFile}"
        require_ssl: true
    desktop:
      resolution:
        width: ${width}
        height: ${height}
      allow_resize: true
      pixel_depth: 24
      # gpu est un SOUS-bloc de desktop (pas une cle de premier niveau).
      gpu:
        hw3d: true
        drinode: "/dev/dri/renderD128"
    encoding:
      # Pas de jpeg_quality/webp_quality ici : kasmvncserver les traduit en
      # « -WebpVideoQuality » que Xkasmvnc de cette version refuse
      # (« Fatal server error: Unrecognized option: -WebpVideoQuality »), ce qui
      # empechait le serveur de demarrer. Les defauts conviennent.
      video_encoding_mode:
        webp_encoding_time: 30
    security:
      brute_force_protection:
        blacklist_threshold: 5
        blacklist_timeout: 300
    server:
      http:
        headers:
          - "Cross-Origin-Embedder-Policy=require-corp"
          - "Cross-Origin-Opener-Policy=same-origin"
        httpd_directory: ${cfg.package}/usr/share/kasmvnc/www
      advanced:
        kasm_password_file: "${cfg.passwordFile}"
        x_authority_file: auto
        # « auto » cherche /usr/share/X11/fonts, inexistant sur NixOS : les
        # polices vivent dans /run/current-system/sw/share/X11/fonts.
        x_font_path: "/run/current-system/sw/share/X11/fonts"
      # Les timeouts sont dans la section auto_shutdown, pas dans advanced.
      auto_shutdown:
        no_user_session_timeout: "never"
        active_user_session_timeout: "never"
        inactive_user_session_timeout: "never"
    user_session:
      new_session_disconnects_existing_exclusive_session: false
      concurrent_connections_prompt: false
      concurrent_connections_prompt_timeout: 10
      idle_timeout: "never"
    runtime_configuration:
      allow_client_to_override_kasm_server_settings: true
      allow_override_standard_vnc_server_settings: true
      allow_override_list:
        - "pointer.enabled"
        - "data_loss_prevention.clipboard.server_to_client.enabled"
        - "data_loss_prevention.clipboard.client_to_server.enabled"
    # Sans ça kasmvncserver lance une invite interactive « Please choose Desktop
    # Environment to run » (select-de.sh) au demarrage : impossible dans une unite
    # systemd (pas de tty), sortie en status=2 INVALIDARGUMENT avant Xvnc.
    command_line:
      prompt: false
  '';
in {

  options.services.kasmvnc = {
    enable = mkEnableOption "KasmVNC - Modern Web-native VNC Server";

    package = mkOption {
      type = types.package;
      default = kasmvncPackage;
      description = "Paquet KasmVNC (binaires dans $out/bin, y compris Xkasmvnc)";
    };

    perlModules = mkOption {
      type = types.listOf types.package;
      default = kasmvncPackage.perlModules;
      description = "Modules CPAN requis par le wrapper perl kasmvncserver (PERL5LIB)";
    };

    # User to run as (systemd user service)
    user = mkOption {
      type = types.str;
      default = "marc";
      description = "User to run KasmVNC (systemd user service)";
    };

    # Display number
    display = mkOption {
      type = types.str;
      default = ":1";
      description = "X/Wayland display number";
    };

    # Geometry
    geometry = mkOption {
      type = types.str;
      default = "1920x1080";
      description = "Desktop resolution (WIDTHxHEIGHT)";
    };

    # Bind address and port
    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Bind address for HTTPS/WebSocket";
    };
    port = mkOption {
      type = types.port;
      default = 443;
      description = "HTTPS port";
    };

    # TLS certificates (required)
    tls = mkOption {
      type = types.submodule {
        options = {
          certFile = mkOption { type = types.path; description = "Path to TLS certificate (PEM)"; };
          keyFile = mkOption { type = types.path; description = "Path to TLS private key (PEM)"; };
        };
      };
      description = "TLS configuration (required for HTTPS/WSS)";
    };

    # Password file (basic auth)
    passwordFile = mkOption {
      type = types.path;
      default = "/home/${cfg.user}/.kasmpasswd";
      description = "Password file generated by kasmvncpasswd";
    };

    # Desktop environment
    desktop = mkOption {
      type = types.enum [ "lxqt" "lxqt-wayland" "xfce" "custom" ];
      default = "lxqt";
      description = "Desktop environment to launch (le .deb 1.5.0 ne sait pas lancer de session Wayland : -xstartup -> X11)";
    };

    # Custom command for desktop=custom
    customCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Custom command to launch (when desktop=custom)";
    };

    # Extra packages for desktop
    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages to install for the desktop";
    };

    # Extra YAML config (merged)
    extraYaml = mkOption {
      type = types.str;
      default = "";
      description = "Extra YAML config merged into kasmvnc.yaml";
    };
  };

  config = mkIf cfg.enable {
    # User setup
    users.users.${cfg.user}.extraGroups = [ "video" "render" "seat" "ssl-cert" ];

    # Packages
    environment.systemPackages = lxqtPkgs ++ cfg.extraPackages ++ [ cfg.package ];

    # Config directory and file
    systemd.tmpfiles.rules = [
      "d /etc/kasmvnc 0750 root ${cfg.user} - -"
      # Xkasmvnc est un binaire Debian : le chemin de xkbcomp est COMPILE dedans
      # (« %s%sxkbcomp » avec XKB_BIN_DIRECTORY=/usr/bin) et l'option -xkbdir ne
      # change que les donnees, pas le binaire. Sans ce lien il meurt sur
      #   sh: /usr/bin/xkbcomp: No such file or directory
      #   XKB: Failed to compile keymap / Fatal server error
      # NixOS n'ayant pas de /usr, on cree le lien declarativement ici.
      "d /usr/bin 0755 root root - -"
      "L+ /usr/bin/xkbcomp - - - - ${pkgs.xkbcomp}/bin/xkbcomp"
    ];

    environment.etc."kasmvnc/kasmvnc.yaml".text = generateConfig + cfg.extraYaml;

    # Session de bureau via script xstartup : c'est le SEUL mecanisme de
    # kasmvncserver 1.5.0 (aucun support de --wayland : « Fatal server error:
    # Unrecognized option: --wayland »). Le script est lance par le wrapper une
    # fois Xvnc en place.
    environment.etc."kasmvnc/xstartup".source = xstartup;

    # Generate password file helper script
    environment.etc."kasmvnc/generate-password".text = ''
      #!/bin/sh
      # kasmvncpasswd n'a PAS d'option -f (usage reel :
      #   kasmvncpasswd -u <utilisateur> [fichier]) et refuse de tourner sans
      # terminal : a lancer depuis une session interactive de l'utilisateur.
      exec ${cfg.package}/bin/kasmvncpasswd -u "${cfg.user}" "$HOME/.kasmpasswd"
    '';
    environment.etc."kasmvnc/generate-password".mode = "0755";

    # Systemd USER service (not system service!)
    systemd.user.services.kasmvnc = {
      description = "KasmVNC Server on display ${cfg.display}";
      # KasmVNC est un serveur X autonome pour l'acces distant : il ne doit pas
      # dependre de la session graphique locale (Xwayland sur :1). En le voulant
      # par default.target il demarre aussi pour un utilisateur linger, sans
      # login local, ce qui est le but d'un acces distant.
      wantedBy = [ "default.target" ];
      # le wrapper perl exige xauth, xkbcomp et hostname sur le PATH, sinon il
      # refuse de demarrer avant meme de lire sa config (inetutils fournit
      # hostname : « couldn't find "hostname" on your PATH »).
      path = [ pkgs.xauth pkgs.xkbcomp pkgs.xrandr pkgs.procps pkgs.inetutils pkgs.which pkgs.util-linux ];
      serviceConfig = {
        Type = "simple";
        Environment = [
          "XDG_SESSION_TYPE=x11"
          "XDG_CURRENT_DESKTOP=LXQt"
          "QT_QPA_PLATFORM=xcb"
          "GDK_BACKEND=x11"
          "XDG_RUNTIME_DIR=%t"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
        ];
        # -xkbdir : Xkasmvnc compile son keymap depuis /usr/share/X11/xkb
        # (absent sur NixOS) et meurt sinon sur « XKB: Failed to compile keymap
        # / Could not start Xvnc ». Le wrapper perl relaie les options inconnues
        # a Xvnc, donc il suffit de lui passer le dossier du store.
        ExecStart = ''
          ${cfg.package}/bin/kasmvncserver ${cfg.display} \
            -xkbdir ${pkgs.xkeyboard_config}/share/X11/xkb \
            -xstartup /etc/kasmvnc/xstartup \
            -fg
        '';
        # une session qui se termine (logout, plantage de LXQt) ne doit pas
        # laisser l'acces distant mort : on relance toujours.
        Restart = "always";
        RestartSec = 10;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Note: user lingering should be enabled via users.users.<name>.linger = true
    # or loginctl enable-linger <user>

    # Amorcage (root) de l'unite utilisateur : une unite utilisateur qui a
    # crash-loop est laissee en start-limit-hit par systemd, et seul un
    # `systemctl --user reset-failed` la debloque. Sans ca, l'acces distant
    # reste mort apres un plantage jusqu'a ce que quelqu'un ouvre une session
    # locale, ce qui est exactement la situation qu'on veut eviter. Ce oneshot
    # systeme est idempotent : reset-failed ne fait rien si l'unite est saine,
    # start ne fait rien si elle tourne deja.
    systemd.services.kasmvnc-kick = {
      description = "Degage l'unite utilisateur kasmvnc (start-limit-hit) et la (re)lance";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        # pas de RemainAfterExit : l'unite reste inactive, donc chaque
        # nixos-rebuild switch la relance (et remet kasmvnc en route apres un
        # plantage), au lieu de la considerer comme deja faite pour toujours.
        Type = "oneshot";
      };
      script = ''
        ${pkgs.systemd}/bin/systemctl --user -M ${cfg.user}@.host reset-failed kasmvnc.service || true
        ${pkgs.systemd}/bin/systemctl --user -M ${cfg.user}@.host start kasmvnc.service || true
      '';
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    networking.firewall.allowedUDPPorts = [ cfg.port ]; # for WebRTC UDP
  };
}