{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.kasmvnc;

  # The old code did `elemAt (builtins.split "x" cfg.geometry) 0/1`:
  # builtins.split returns [prefix, groups, suffix], so index 0 does give
  # "1920" but index 1 is the LIST of capture groups, not "1080". The
  # height therefore went empty into the YAML. splitString gives exactly the two
  # expected pieces.
  geometryParts = splitString "x" cfg.geometry;
  width = elemAt geometryParts 0;
  height = elemAt geometryParts 1;

  # perl + the CPAN modules that the kasmvncserver wrapper imports and that the deb does
  # not provide (the deb only ships its own KasmVNC::* modules).
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

    # kasmvncserver and kasmvncconfig are PERL SCRIPTS, not ELF: the old
    # guard `if file .../kasmvncserver | grep -q ELF` tested the script, so it was
    # always FALSE and no binary was patched -> kasmvncpasswd exited with
    # "error while loading shared libraries: libcrypt.so.1". autoPatchelfHook
    # patches every ELF in the deb and resolves the libs from buildInputs.
    nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook pkgs.patchelf pkgs.perl pkgs.makeWrapper ];
    buildInputs = [
      # libxcrypt-legacy and NOT libxcrypt: the .deb asks for libcrypt.so.1 (Debian
      # soname) whereas pkgs.libxcrypt only provides libcrypt.so.2. This is
      # exactly the error "libcrypt.so.1: cannot open shared object file".
      pkgs.libxcrypt-legacy pkgs.glibc pkgs.gcc pkgs.libx11 pkgs.libxcb pkgs.libxkbcommon
      pkgs.wayland pkgs.libva pkgs.libdrm pkgs.mesa pkgs.libunwind pkgs.pixman
      pkgs.freetype pkgs.systemd pkgs.libxshmfence pkgs.libgbm
      # non-deprecated names (pkgs.xorg.* emits an evaluation warning)
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
      # ALL binaries in $out/bin: kasmvncserver (perl) locates Xkasmvnc
      # in the directory of $0 (DetectBinariesDir), so the symlinks must be
      # side by side (systemPackages then exposes them in sw/bin).
      mkdir -p $out/bin
      for b in kasmvncserver kasmvncpasswd kasmvncconfig kasmxproxy Xkasmvnc; do
        ln -sf $out/usr/bin/$b $out/bin/$b
      done
      # The perl wrapper looks LITERALLY for $exedir/Xvnc and $exedir/vncpasswd
      # (lines 493-508) whereas the deb only ships Xkasmvnc / kasmvncpasswd:
      # without these two aliases it dies on: couldn't find ".../bin/Xvnc".
      ln -sf $out/usr/bin/Xkasmvnc $out/bin/Xvnc
      ln -sf $out/usr/bin/kasmvncpasswd $out/bin/vncpasswd
      # kasmvncserver/kasmvncconfig have a Debian shebang #!/usr/bin/perl that
      # does not exist on NixOS ("No such file or directory" at runtime): the
      # stdenv fixupPhase does not patch $out/usr/bin, so explicitly here.
      patchShebangs $out/usr/bin
      # The wrapper loads its default values from
      # /usr/share/kasmvnc/kasmvnc_defaults.yaml (Debian path absent on NixOS,
      # so the defaults were never read). We rewrite it to the store.
      substituteInPlace $out/usr/bin/kasmvncserver \
        --replace-fail "/usr/share/kasmvnc/" "$out/usr/share/kasmvnc/"
      # The wrapper computes the desktop selector via LocalSelectDePath()
      # ("$exedir/../builder/startup/deb/select-de.sh", tree of the KasmVNC
      # repo) whereas the deb ships the file in usr/lib/kasmvncserver/:
      # without this alias the session exits with status=2 INVALIDARGUMENT before Xvnc.
      mkdir -p $out/builder/startup/deb
      cp $out/usr/lib/kasmvncserver/select-de.sh $out/builder/startup/deb/select-de.sh
      runHook postInstall
    '';

    # The perl wrapper must be self-contained: PERL5LIB (its own modules + the
    # CPAN modules missing from the deb) and the PATH (xauth, xkbcomp) are baked into a
    # wrapper, so that we no longer need to export anything before
    # launching kasmvncserver (neither in the shell, nor in the systemd unit).
    postFixup = ''
      wrapProgram $out/bin/kasmvncserver \
        --prefix PERL5LIB : "${perlLib}/lib/perl5/site_perl:$out/usr/share/perl5" \
        --prefix PATH : "${lib.makeBinPath [ pkgs.xauth pkgs.xkbcomp pkgs.xrandr pkgs.procps pkgs.inetutils pkgs.which pkgs.util-linux ]}"
    '';

    # The perl wrapper loads the KasmVNC::* modules (shipped in
    # usr/share/perl5) and a few CPAN modules missing from the deb: PERL5LIB is
    # set by the module (services.kasmvnc.environment), not here.
    passthru = {
      # Exact list of modules missing from the deb, obtained by running the wrapper:
      # kasmvncserver imports YAML::Tiny (KasmVNC/Config.pm) and
      # Hash::Merge::Simple in addition to the DateTime/Switch/List::MoreUtils modules.
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

  # Desktop session launched by xstartup (X11: kasmvncserver 1.5.0 has no
  # wayland mode). startlxqt inherits the session bus provided by the systemd unit.
  # PATH: the unit sets a short `path` (xauth, xkbcomp, hostname), which
  # replaces systemd's default PATH and makes the system profile disappear.
  # But startlxqt execs `lxqt-session` by its name, hence "exec: lxqt-session: not
  # found" then the immediate end of the session (and Xvnc stops). We therefore
  # put the system profile first: that is where marc's LXQt packages live
  # (lxqt-session, lxqt-panel, pcmanfm-qt, lxqt-runner).
  xstartup = pkgs.writeShellScript "kasmvnc-xstartup" (
    if cfg.desktop == "custom" then cfg.customCommand
    else if cfg.desktop == "xfce" then "exec ${pkgs.xfce.xfce4-session}/bin/xfce4-session"
    else if cfg.desktop == "plasma" then ''
      # startplasma-x11 is the entry point of a KDE session: it sets up the session
      # bus, ksmserver, kwin_x11, kded, plasmashell. Do NOT launch
      # plasmashell by hand: the session would be without a window manager.
      #
      # The unit's PATH is short (xauth, xkbcomp, ...). startplasma-x11
      # calls kwin_x11 and plasmashell by their name: without the system profile it
      # exits with "kwin_x11: not found" and the session dies immediately.
      # /run/wrappers/bin first: the sudo of the system profile is NOT setuid
      # (cf. services/terminal). A terminal opened in the Kasm desktop inherits
      # this order, so sudo and the other wrappers work there.
      export PATH="/run/wrappers/bin:/run/current-system/sw/bin:${pkgs.kdePackages.plasma-workspace}/bin:$PATH"
      export XDG_SESSION_TYPE=x11
      export XDG_CURRENT_DESKTOP=KDE
      export XDG_SESSION_DESKTOP=KDE
      export DESKTOP_SESSION=plasma
      export KDE_FULL_SESSION=true
      export KDE_SESSION_VERSION=6
      export QT_QPA_PLATFORM=xcb
      export GDK_BACKEND=x11
      # startplasma-x11 creates a session bus ONLY if
      # DBUS_SESSION_BUS_ADDRESS is empty (plasma-dbus-run-session-if-needed).
      # The unit points to %t/bus: if this socket does not exist (no user
      # dbus.socket active), KDE settles for the dead pointer and dies on
      # "Failed to connect to socket". We clear it only in that case.
      bus="''${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
      if [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && [ ! -S "$bus" ]; then
        unset DBUS_SESSION_BUS_ADDRESS
      fi
      exec ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-x11
    ''
    else ''
      # /run/wrappers/bin first (cf. plasma branch above).
      export PATH="/run/wrappers/bin:/run/current-system/sw/bin:${pkgs.lxqt.lxqt-session}/bin:$PATH"
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

  # ---------------------------------------------------------------------------
  # PLASMA 6 (desktop = "plasma"): full remote desktop, in X11.
  #
  # KasmVNC cannot host a Wayland session (Xkasmvnc IS an X server;
  # kasmtech/KasmVNC#193: running a Wayland DE inside it would require
  # patching KWin). The Wayland mode of the `desktop` option therefore does not exist:
  # Plasma runs as an X11 session (startplasma-x11), which is fully
  # supported by Plasma 6 and sufficient for the goal (clickable desktop, terminal,
  # browser, taskbar).
  #
  # The package list is the one from nixos/modules/services/desktop-managers/
  # plasma6.nix (nixpkgs 26.05), authoritative source for "what a Plasma session
  # expects". This module is NOT enabled (services.desktopManager.plasma6): it
  # is global (fonts.fontconfig.defaultFonts, xdg.portal.configPackages,
  # qt.enable, programs.kde-pim, orca...) and would modify marc's local niri
  # session. Everything is therefore confined here + to the XDG_* of the kasmvnc unit.
  #
  # DELIBERATELY EXCLUDED from the plasma6 set (each package added here sets up its
  # systemd units in /run/current-system/sw/share/systemd/user, which marc's
  # user manager shares with his niri session):
  #   baloo, baloo-widgets, kunifiedpush: their units are
  #     WantedBy=graphical-session.target, so they would ALSO start in
  #     niri (file indexer + push notification distributor). Verified
  #     in the shipped .service files. baloo indexing is cut off anyway
  #     by the baloofilerc of plasmaConfigDir.
  #   drkonqi: sets up a SYSTEM crash handler
  #     (drkonqi-coredump-processor@) that reports marc's core dumps into his
  #     local session. Unrelated to a remote desktop.
  #   kwallet-pam: requires PAM integration (security.pam.services.*.kwallet)
  #     that a KasmVNC session does not have (no PAM login): its unit
  #     plasma-kwallet-pam.service (Wants of plasma-workspace.target) would fail.
  # ---------------------------------------------------------------------------
  plasmaLookAndFeel = pkgs.runCommand "plasma-look-and-feel-hermes-kasm" { } ''
    dir=$out/share/plasma/look-and-feel/org.hermes.kasm.desktop
    install -d $dir/contents/layouts
    install -m 444 ${./plasma/metadata.json} $dir/metadata.json
    install -m 444 ${./plasma/desktop-layout.js} $dir/contents/layouts/org.kde.plasma.desktop-layout.js
    install -m 444 ${./plasma/defaults} $dir/contents/defaults
  '';

  plasmaPkgs =
    with pkgs.kdePackages;
    [
      # Frameworks that the system profile needs for its Qt plugins
      qtwayland qtsvg frameworkintegration kauth kcoreaddons kded kfilemetadata
      kguiaddons kiconthemes kimageformats qtimageformats kio kio-admin
      kio-extras kio-fuse knighttime kpackage kservice kwallet kwalletmanager
      plasma-activities solid phonon-vlc
      # Plasma core
      kwin
      kwin-x11 # THE window manager of an X11 session (kwin alone = Wayland)
      kscreen
      libkscreen
      kscreenlocker
      kactivitymanagerd
      kde-cli-tools
      kglobalacceld
      kwrited
      milou
      kdegraphics-thumbnailers
      polkit-kde-agent-1
      plasma-desktop
      plasma-workspace
      kde-inotify-survey
      # Application integration
      libplasma
      plasma-integration
      kde-gtk-config
      # Theming
      breeze
      breeze-icons
      breeze-gtk
      ocean-sound-theme
      qqc2-breeze-style
      qqc2-desktop-style
      # Extras + settings
      kdeplasma-addons
      plasma-workspace-wallpapers
      kmenuedit
      kinfocenter
      plasma-systemmonitor
      ksystemstats
      libksysguard
      systemsettings
      kcmutils
      ksshaskpass
      # Applications: the requested terminal and browser, plus the minimum
      konsole
      dolphin
      dolphin-plugins
      ark
      spectacle
      kate
      ktexteditor
      gwenview
      kcalc
      plasma-browser-integration
      # Sessions and portals
      xdg-desktop-portal-kde
      kwayland-integration
      plasma5support
      kdecoration
      kirigami
      (lib.getBin qttools) # qdbus, expected by several KDE scripts
      plasmaLookAndFeel
    ]
    # powerdevil is NOT installed: tower has powerManagement.enable = false,
    # so no upower, and above all NO screen power-off or suspend during
    # a remote session (that is the underlying reason).
    ++ lib.optional config.networking.networkmanager.enable plasma-nm
    ++ lib.optional
      (config.services.pipewire.pulse.enable || config.services.pulseaudio.enable)
      plasma-pa
    ++ [
      # The requested browser, and the two packages that the nixpkgs plasma6
      # module puts in systemPackages for desktop integration.
      pkgs.librewolf
      pkgs.hicolor-icon-theme
      pkgs.xdg-user-dirs
      pkgs.xdg-utils
    ];

  # Plasma DATA tree, isolated from the system profile. Without it,
  # plasmashell finds nothing: tower's profile does not link share/plasma,
  # share/kservices6, share/kglobalaccel, share/kpackage, share/solid... (the
  # nixpkgs plasma6 module fixes this with a GLOBAL environment.pathsToLink =
  # [ "/share" ], out of the question on a machine whose local desktop
  # is niri). We therefore export this folder into the XDG_DATA_DIRS of the only
  # kasmvnc unit: the niri session sees nothing there.
  plasmaDataEnv = pkgs.buildEnv {
    name = "kasmvnc-plasma-data";
    paths = plasmaPkgs;
    pathsToLink = [ "/share" "/lib/qt-6" "/libexec" "/etc/xdg" ];
    ignoreCollisions = true;
  };

  # DEFAULT KDE settings, exported into the XDG_CONFIG_DIRS of the same unit
  # (so the niri session does not see them either). Without kscreenlockerrc,
  # the remote screen locks after 5 min of inactivity, which makes the
  # desktop unusable remotely.
  plasmaConfigDir = pkgs.linkFarm "kasmvnc-plasma-xdg" [
    {
      name = "kdeglobals";
      path = pkgs.writeText "kasmvnc-kdeglobals" ''
        [KDE]
        LookAndFeelPackage=org.hermes.kasm.desktop
      '';
    }
    {
      name = "kscreenlockerrc";
      path = pkgs.writeText "kasmvnc-kscreenlockerrc" ''
        [Daemon]
        Autolock=false
        LockOnResume=false
      '';
    }
    {
      name = "baloofilerc";
      path = pkgs.writeText "kasmvnc-baloofilerc" ''
        [Basic Settings]
        Indexing-Enabled=false
      '';
    }
    {
      name = "powermanagementprofilesrc";
      path = pkgs.writeText "kasmvnc-powermanagementprofilesrc" ''
        [AC][DimDisplay]
        idleTime=0

        [AC][SuspendSession]
        idleTime=0
        suspendType=0
        lockScreen=false
      '';
    }
  ];

  desktopPkgs = if cfg.desktop == "plasma" then plasmaPkgs else lxqtPkgs;

  # Generate kasmvnc.yaml, with the REAL schema of KasmVNC 1.5.0. The old file
  # nested network/desktop/encoding/gpu/advanced under a `server:` block that
  # does not exist at this level: kasmvncserver answered
  #   "Unsupported config keys found: server.desktop.allow_resize, ..."
  # and therefore ignored ALL the config (resolution, port, headers, password).
  # The top-level keys are: network, desktop, encoding, security,
  # server (http/advanced/auto_shutdown), user_session, runtime_configuration.
  # Reference: usr/share/kasmvnc/kasmvnc_defaults.yaml and etc/kasmvnc/kasmvnc.yaml
  # shipped in the .deb.
  generateConfig = ''
    network:
      # Accepted values: http | vnc (checked by kasmvncserver:
      # "network.protocol 'https': must be one of [http, vnc]"). Web TLS
      # comes from network.ssl.require_ssl, not from the protocol.
      protocol: http
      interface: "${cfg.bindAddress}"
      # KasmVNC 1.5.0 has NO network.port: the web port is websocket_port.
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
      # gpu is a SUB-block of desktop (not a top-level key).
      gpu:
        hw3d: true
        drinode: "/dev/dri/renderD128"
    encoding:
      # No jpeg_quality/webp_quality here: kasmvncserver translates them into
      # "-WebpVideoQuality" which Xkasmvnc of this version refuses
      # ("Fatal server error: Unrecognized option: -WebpVideoQuality"), which
      # prevented the server from starting. The defaults are fine.
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
        # "auto" looks for /usr/share/X11/fonts, nonexistent on NixOS: the
        # fonts live in /run/current-system/sw/share/X11/fonts.
        x_font_path: "/run/current-system/sw/share/X11/fonts"
      # The timeouts are in the auto_shutdown section, not in advanced.
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
    # Without this kasmvncserver launches an interactive prompt "Please choose Desktop
    # Environment to run" (select-de.sh) at startup: impossible in a systemd
    # unit (no tty), exits with status=2 INVALIDARGUMENT before Xvnc.
    command_line:
      prompt: false
  '';
in {

  options.services.kasmvnc = {
    enable = mkEnableOption "KasmVNC - Modern Web-native VNC Server";

    package = mkOption {
      type = types.package;
      default = kasmvncPackage;
      description = "KasmVNC package (binaries in $out/bin, including Xkasmvnc)";
    };

    perlModules = mkOption {
      type = types.listOf types.package;
      default = kasmvncPackage.perlModules;
      description = "CPAN modules required by the kasmvncserver perl wrapper (PERL5LIB)";
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
      type = types.enum [ "lxqt" "lxqt-wayland" "xfce" "plasma" "custom" ];
      default = "lxqt";
      description = "Desktop environment to launch (the .deb 1.5.0 cannot launch a Wayland session: -xstartup -> X11)";
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

    # Not exposed in kasmvnc.yaml (confirmed by kasmtech/KasmVNC#284): only a
    # CLI flag relayed to Xkasmvnc disables it. To use when another layer
    # (Pangolin SSO) already gates access, otherwise anyone who reaches the port
    # gets in without a password.
    disableBasicAuth = mkOption {
      type = types.bool;
      default = false;
      description = "Disables KasmVNC's own HTTP Basic Auth (-DisableBasicAuth). To be reserved for deployments already gated by an upstream SSO (e.g. Pangolin).";
    };
  };

  config = mkIf cfg.enable {
    # User setup
    users.users.${cfg.user}.extraGroups = [ "video" "render" "seat" "ssl-cert" ];

    # Packages
    environment.systemPackages = desktopPkgs ++ cfg.extraPackages ++ [ cfg.package ];

    # Config directory and file
    systemd.tmpfiles.rules = [
      "d /etc/kasmvnc 0750 root ${cfg.user} - -"
      # Xkasmvnc is a Debian binary: the xkbcomp path is COMPILED into it
      # ("%s%sxkbcomp" with XKB_BIN_DIRECTORY=/usr/bin) and the -xkbdir option only
      # changes the data, not the binary. Without this link it dies on
      #   sh: /usr/bin/xkbcomp: No such file or directory
      #   XKB: Failed to compile keymap / Fatal server error
      # Since NixOS has no /usr, we create the link declaratively here.
      "d /usr/bin 0755 root root - -"
      "L+ /usr/bin/xkbcomp - - - - ${pkgs.xkbcomp}/bin/xkbcomp"
    ];

    environment.etc."kasmvnc/kasmvnc.yaml".text = generateConfig + cfg.extraYaml;

    # Desktop session via the xstartup script: it is the ONLY mechanism of
    # kasmvncserver 1.5.0 (no support for --wayland: "Fatal server error:
    # Unrecognized option: --wayland"). The script is launched by the wrapper once
    # Xvnc is in place.
    environment.etc."kasmvnc/xstartup".source = xstartup;

    # Generate password file helper script
    environment.etc."kasmvnc/generate-password".text = ''
      #!/bin/sh
      # kasmvncpasswd has NO -f option (actual usage:
      #   kasmvncpasswd -u <user> [file]) and refuses to run without
      # a terminal: to be run from an interactive session of the user.
      exec ${cfg.package}/bin/kasmvncpasswd -u "${cfg.user}" "$HOME/.kasmpasswd"
    '';
    environment.etc."kasmvnc/generate-password".mode = "0755";

    # Systemd USER service (not system service!)
    systemd.user.services.kasmvnc = {
      description = "KasmVNC Server on display ${cfg.display}";
      # The unit is installed in /etc/systemd/user (visible to all linger
      # users: hermes also starts a user manager with
      # default.target active). ConditionUser restricts it to the account of the
      # configured user: without this, hermes launched a second
      # instance on :20 (conflict, crash-loop, and failure of its user
      # activation at switch -> rc=4).
      unitConfig.ConditionUser = cfg.user;
      # KasmVNC is a standalone X server for remote access: it must not
      # depend on the local graphical session (Xwayland on :1). By wanting it
      # via default.target it also starts for a linger user, without
      # a local login, which is the goal of remote access.
      wantedBy = [ "default.target" ];
      # the perl wrapper requires xauth, xkbcomp and hostname on the PATH, otherwise it
      # refuses to start even before reading its config (inetutils provides
      # hostname: couldn't find "hostname" on your PATH).
      # setxkbmap: kded6 configures keyboard layouts via this binary and
      # logs "Can't find setxkbmap - keyboard layouts won't be
      # configured" without it.
      path = [ pkgs.xauth pkgs.xkbcomp pkgs.xrandr pkgs.setxkbmap pkgs.procps pkgs.inetutils pkgs.which pkgs.util-linux ];
      serviceConfig = {
        Type = "simple";
        # After a switch, an old instance (previous session, orphan process
        # outside the unit's current management) may hold the display:
        # Xvnc then answers "A VNC server is already running as :20" and exits with
        # 29 -> crash-loop. This pre-hook purges any instance on this display (it
        # is by definition obsolete: we start the new one) then the leftovers
        # (lock, socket). Run as the unit's user.
        ExecStartPre = [
          # display passed as an ARGUMENT (concatenated in the same command): in
          # a list, systemd would treat each element as a separate command
          # ("Unable to locate executable '20'").
          (pkgs.writeShellScript "kasmvnc-cleanup" ''
            d="''${1#:}"
            pkill -f "Xvnc :''${d}" 2>/dev/null || true
            rm -f "/tmp/.X''${d}-lock" "/tmp/.X11-unix/X''${d}"
          '' + " ${cfg.display}")
        ];
        Environment =
          [
            "XDG_SESSION_TYPE=x11"
            "QT_QPA_PLATFORM=xcb"
            "GDK_BACKEND=x11"
            "XDG_RUNTIME_DIR=%t"
            "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
          ]
          ++ (
            if cfg.desktop == "plasma" then
              [
                # The remote KDE session lives in ITS OWN data tree
                # (plasmaDataEnv) and ITS OWN default settings (plasmaConfigDir).
                # tower's system profile links neither share/plasma, nor
                # share/kservices6, nor share/kglobalaccel: without these XDG_*,
                # plasmashell starts without applets, without look-and-feel and without
                # keyboard shortcuts. None of that leaks out of this unit.
                "XDG_CURRENT_DESKTOP=KDE"
                "XDG_SESSION_DESKTOP=KDE"
                "DESKTOP_SESSION=plasma"
                "KDE_FULL_SESSION=true"
                "KDE_SESSION_VERSION=6"
                # The Qt platform theme only loads if the plugin is
                # reachable: QT_PLUGIN_PATH is therefore restricted to plasmaDataEnv,
                # not to the system profile (no global qt.enable: a
                # QT_PLUGIN_PATH pointing at Qt6 plugins would break the
                # Qt5 applications of marc's niri session).
                "QT_QPA_PLATFORMTHEME=kde"
                "QT_PLUGIN_PATH=${plasmaDataEnv}/lib/qt-6/plugins"
                "QML2_IMPORT_PATH=${plasmaDataEnv}/lib/qt-6/qml"
                "XDG_DATA_DIRS=${plasmaDataEnv}/share:/run/current-system/sw/share:/nix/var/nix/profiles/default/share"
                "XDG_CONFIG_DIRS=${plasmaConfigDir}:/etc/xdg:%h/.config/kdedefaults"
              ]
            else
              [
                "XDG_CURRENT_DESKTOP=LXQt"
              ]
          );
        # -xkbdir: Xkasmvnc compiles its keymap from /usr/share/X11/xkb
        # (absent on NixOS) and dies otherwise on "XKB: Failed to compile keymap
        # / Could not start Xvnc". The perl wrapper relays unknown options
        # to Xvnc, so it is enough to pass it the store folder.
        ExecStart = ''
          ${cfg.package}/bin/kasmvncserver ${cfg.display} \
            -xkbdir ${pkgs.xkeyboard_config}/share/X11/xkb \
            -xstartup /etc/kasmvnc/xstartup \
            ${lib.optionalString cfg.disableBasicAuth "-DisableBasicAuth \\"}
            -fg
        '';
        # a session that ends (logout, LXQt crash) must not
        # leave remote access dead: we always restart.
        Restart = "always";
        RestartSec = 10;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Note: user lingering should be enabled via users.users.<name>.linger = true
    # or loginctl enable-linger <user>

    # Kick-start (root) of the user unit: a user unit that has
    # crash-looped is left in start-limit-hit by systemd, and only a
    # `systemctl --user reset-failed` unblocks it. Without this, remote access
    # stays dead after a crash until someone opens a
    # local session, which is exactly the situation we want to avoid. This oneshot
    # system unit is idempotent: reset-failed does nothing if the unit is healthy,
    # start does nothing if it is already running.
    systemd.services.kasmvnc-kick = {
      description = "Clears the kasmvnc user unit (start-limit-hit) and (re)starts it";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        # no RemainAfterExit: the unit stays inactive, so each
        # nixos-rebuild switch restarts it (and brings kasmvnc back up after a
        # crash), instead of considering it done forever.
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