{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.kasmvnc;

  # Fetch KasmVNC from GitHub Releases (not in nixpkgs)
  kasmvncPackage = pkgs.stdenv.mkDerivation rec {
    pname = "kasmvnc";
    version = "1.5.0";

    src = pkgs.fetchurl {
      url = "https://github.com/kasmtech/KasmVNC/releases/download/v${version}/kasmvncserver_noble_${version}_amd64.deb";
      sha256 = "sha256-9Zn+AuIXW5gXthZfdKXSvr3HMRjd6Rgbo0EJY77Xrh4=";
    };

    nativeBuildInputs = [ pkgs.dpkg pkgs.patchelf ];
    buildInputs = [
      pkgs.glibc pkgs.gcc pkgs.libx11 pkgs.libxcb pkgs.libxkbcommon
      pkgs.wayland pkgs.libva pkgs.libdrm pkgs.mesa
      pkgs.openssl pkgs.zlib pkgs.libjpeg_turbo pkgs.libpng pkgs.libwebp
    ];

    dontUnpack = true;

    installPhase = ''
      dpkg -x $src $out
      # The deb extracts to root/usr/..., so move to correct location
      if [ -d $out/root ]; then
        mv $out/root/* $out/
        rmdir $out/root
      fi
      # Check if binary is ELF before patchelf
      if file $out/usr/bin/kasmvncserver | grep -q ELF; then
        patchelf --set-rpath "$out/usr/lib/x86_64-linux-gnu:$out/lib" $out/usr/bin/kasmvncserver
        patchelf --set-rpath "$out/usr/lib/x86_64-linux-gnu:$out/lib" $out/usr/bin/kasmvncpasswd
      fi
      # Move binaries to $out/bin
      mkdir -p $out/bin
      ln -s $out/usr/bin/kasmvncserver $out/bin/kasmvncserver
      ln -s $out/usr/bin/kasmvncpasswd $out/bin/kasmvncpasswd
      ln -s $out/usr/bin/kasmvncconfig $out/bin/kasmvncconfig
    '';
  };

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

  # Generate kasmvnc.yaml config
  generateConfig = ''
    server:
      http:
        headers:
          - "Cross-Origin-Embedder-Policy=require-corp"
          - "Cross-Origin-Opener-Policy=same-origin"
        httpd_directory: ${kasmvncPackage}/usr/share/kasmvnc/www
      network:
        protocol: https
        interface: "${cfg.bindAddress}"
        port: ${toString cfg.port}
        websocket_port: auto
        use_ipv4: true
        use_ipv6: true
        udp:
          public_ip: auto
          port: auto
          stun_server: "stun.l.google.com:19302"
      ssl:
        pem_certificate: "${cfg.tls.certFile}"
        pem_key: "${cfg.tls.keyFile}"
        require_ssl: true
      desktop:
        resolution:
          width: ${toString (builtins.elemAt (builtins.split "x" cfg.geometry) 0)}
          height: ${toString (builtins.elemAt (builtins.split "x" cfg.geometry) 1)}
        allow_resize: true
        pixel_depth: 24
      gpu:
        hw3d: true
        drinode: "/dev/dri/renderD128"
      encoding:
        prefer_h264: true
        prefer_hevc: true
        prefer_av1: true
        prefer_vp9: true
        prefer_vp8: true
        lossless: false
        webp_quality: 80
        jpeg_quality: 85
      security:
        brute_force_protection:
          enabled: true
          blacklist_threshold: 5
          blacklist_timeout: 300
      advanced:
        kasm_password_file: "${cfg.passwordFile}"
        x_authority_file: auto
        auto_shutdown: false
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
    '';
in {

  options.services.kasmvnc = {
    enable = mkEnableOption "KasmVNC - Modern Web-native VNC Server";

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
      type = types.enum [ "lxqt-wayland" "plasma-wayland" "xfce" "custom" ];
      default = "lxqt-wayland";
      description = "Desktop environment to launch";
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
    environment.systemPackages = lxqtPkgs ++ cfg.extraPackages ++ [ kasmvncPackage ];

    # Config directory and file
    systemd.tmpfiles.rules = [
      "d /etc/kasmvnc 0750 root ${cfg.user} - -"
    ];

    environment.etc."kasmvnc/kasmvnc.yaml".text = generateConfig + cfg.extraYaml;

    # Generate password file helper script
    environment.etc."kasmvnc/generate-password".text = ''
      #!/bin/sh
      # Run as user: kasmvncpasswd -f ~/.kasmpasswd
      exec ${kasmvncPackage}/bin/kasmvncpasswd -f "$HOME/.kasmpasswd"
    '';
    environment.etc."kasmvnc/generate-password".mode = "0755";

    # Systemd USER service (not system service!)
    systemd.user.services.kasmvnc = {
      description = "KasmVNC Server on display ${cfg.display}";
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        Environment = [
          "XDG_SESSION_TYPE=wayland"
          "XDG_CURRENT_DESKTOP=LXQt"
          "QT_QPA_PLATFORM=wayland"
          "GDK_BACKEND=wayland,x11"
          "XDG_RUNTIME_DIR=%t"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
        ];
        ExecStartPre = "+${kasmvncPackage}/bin/kasmvncpasswd -f ${cfg.passwordFile} || true";
        ExecStart = ''
          ${kasmvncPackage}/bin/kasmvncserver ${cfg.display} \
            --wayland \
            -- ${pkgs.kdePackages.kwin}/bin/kwin_wayland --xwayland --exit-with-session=${pkgs.lxqt.lxqt-session}/bin/startlxqt
        '';
        Restart = "on-failure";
        RestartSec = 5;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Note: user lingering should be enabled via users.users.<name>.linger = true
    # or loginctl enable-linger <user>

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    networking.firewall.allowedUDPPorts = [ cfg.port ]; # for WebRTC UDP
  };
}