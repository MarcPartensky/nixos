{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustguac;

  # Fetch rustguac pre-built binary from GitHub Releases (not in nixpkgs yet)
  rustguacPackage = pkgs.stdenv.mkDerivation rec {
    pname = "rustguac";
    version = "1.10.0";

    src = pkgs.fetchurl {
      url = "https://github.com/sol1/rustguac/releases/download/v${version}/rustguac-${version}-linux-amd64.tar.gz";
      sha256 = "sha256-z9MPBTpb/qWby9KYT3ELSisy06mbvfIE/VSpmcsIuQg=";
    };

    nativeBuildInputs = [ ];

    installPhase = ''
      tar -xzf $src
      mkdir -p $out/bin
      cp rustguac-*/bin/rustguac $out/bin/
    '';
  };

  guacdPackage = pkgs.guacamole-server;

  # Generate api_keys TOML section
    apiKeysToml = "";

  # Generate oidc TOML section
  oidcToml = optionalString (cfg.oidc != null) ''
    [oidc]
    issuer_url = "${cfg.oidc.issuerUrl}"
    client_id = "${cfg.oidc.clientId}"
    client_secret = "${cfg.oidc.clientSecret}"
    redirect_url = "${cfg.oidc.redirectUrl}"
    scopes = [${concatStringsSep " " (map (s: "\"${s}\"") cfg.oidc.scopes)}]
    username_claim = "${cfg.oidc.usernameClaim}"
    groups_claim = "${cfg.oidc.groupsClaim}"
  '';

  # Generate tls TOML section
  tlsToml = optionalString (cfg.tls != null) ''
    tls_cert = "${cfg.tls.certFile}"
    tls_key = "${cfg.tls.keyFile}"
  '';
in {

  options.services.rustguac = {
    enable = mkEnableOption "rustguac - Lightweight Rust replacement for Apache Guacamole";

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for rustguac HTTP server";
    };
    port = mkOption {
      type = types.port;
      default = 8089;
      description = "Port for rustguac HTTP server";
    };

    tls = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          certFile = mkOption { type = types.path; description = "Path to TLS certificate"; };
          keyFile = mkOption { type = types.path; description = "Path to TLS private key"; };
        };
      });
      default = null;
      description = "TLS configuration (null = use nginx reverse proxy)";
    };

    guacd = mkOption {
      type = types.submodule {
        options = {
          host = mkOption { type = types.str; default = "127.0.0.1"; };
          port = mkOption { type = types.port; default = 4822; };
          tls = mkOption { type = types.bool; default = true; };
        };
      };
      default = { host = "127.0.0.1"; port = 4822; tls = true; };
    };

    vault = mkOption {
      type = types.submodule {
        options = {
          address = mkOption { type = types.str; default = "http://127.0.0.1:8200"; };
          token = mkOption { type = types.str; description = "Vault root token (or use AppRole)"; };
          mountPath = mkOption { type = types.str; default = "secret"; };
          connectionsPath = mkOption { type = types.str; default = "connections"; };
        };
      };
      default = { address = "http://127.0.0.1:8200"; mountPath = "secret"; connectionsPath = "connections"; };
    };

    oidc = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          issuerUrl = mkOption { type = types.str; description = "OIDC issuer URL (e.g. https://auth.example.com)"; };
          clientId = mkOption { type = types.str; };
          clientSecret = mkOption { type = types.str; };
          redirectUrl = mkOption { type = types.str; };
          scopes = mkOption { type = types.listOf types.str; default = [ "openid" "profile" "email" ]; };
          usernameClaim = mkOption { type = types.str; default = "email"; };
          groupsClaim = mkOption { type = types.str; default = "groups"; };
        };
      });
      default = null;
      description = "OIDC configuration (null = disabled, use API keys)";
    };

    apiKeys = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption { type = types.str; };
          keyHash = mkOption { type = types.str; description = "SHA-256 hash of the API key"; };
          roles = mkOption { type = types.listOf (types.enum [ "admin" "poweruser" "operator" "viewer" ]); default = [ "viewer" ]; };
          ipAllowlist = mkOption { type = types.listOf types.str; default = [ ]; };
          expiry = mkOption { type = types.nullOr types.str; default = null; };
        };
      });
      default = [ ];
    };

    recording = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          storagePath = mkOption { type = types.path; default = "/var/lib/rustguac/recordings"; };
          maxSize = mkOption { type = types.str; default = "10G"; };
          maxAge = mkOption { type = types.str; default = "30d"; };
        };
      };
      default = { enable = true; storagePath = "/var/lib/rustguac/recordings"; };
    };

    rateLimit = mkOption {
      type = types.submodule {
        options = {
          enabled = mkOption { type = types.bool; default = true; };
          requestsPerMinute = mkOption { type = types.int; default = 60; };
        };
      };
      default = { enabled = true; requestsPerMinute = 60; };
    };

    user = mkOption { type = types.str; default = "rustguac"; };
    group = mkOption { type = types.str; default = "rustguac"; };

    extraConfig = mkOption { type = types.str; default = ""; };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/rustguac";
      description = "rustguac service user";
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d /var/lib/rustguac 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.recording.storagePath} 0750 ${cfg.user} ${cfg.group} - -"
      "d /etc/rustguac 0750 ${cfg.user} ${cfg.group} - -"
    ];

    environment.etc."rustguac/config.toml".text = ''
      [server]
      host = "${cfg.host}"
      port = ${toString cfg.port}
      ${tlsToml}

      [guacd]
      host = "${cfg.guacd.host}"
      port = ${toString cfg.guacd.port}
      tls = ${toString cfg.guacd.tls}

      [vault]
      address = "${cfg.vault.address}"
      token = "${cfg.vault.token}"
      mount_path = "${cfg.vault.mountPath}"
      connections_path = "${cfg.vault.connectionsPath}"

      ${oidcToml}

      [recording]
      enabled = ${toString cfg.recording.enable}
      storage_path = "${cfg.recording.storagePath}"
      max_size = "${cfg.recording.maxSize}"
      max_age = "${cfg.recording.maxAge}"

      [rate_limit]
      enabled = ${toString cfg.rateLimit.enabled}
      requests_per_minute = ${toString cfg.rateLimit.requestsPerMinute}

      ${cfg.extraConfig}
    '';

    systemd.services.rustguac = {
      description = "rustguac - Lightweight Rust replacement for Apache Guacamole";
      after = [ "network.target" "vault.service" ];
      wants = [ "vault.service" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${rustguacPackage}/bin/rustguac --config /etc/rustguac/config.toml";
        Restart = "on-failure";
        RestartSec = 5;
        LimitNOFILE = 65536;
        Environment = "RUST_LOG=info";
        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
      };
    };

    systemd.services.guacd = {
      description = "guacd - Guacamole proxy daemon";
      after = [ "network.target" ];
      serviceConfig = {
        User = "guacd";
        Group = "guacd";
        ExecStart = "${guacdPackage}/sbin/guacd -f -L ${cfg.guacd.host} -p ${toString cfg.guacd.port} ${optionalString cfg.guacd.tls "-t"}";
        Restart = "on-failure";
      };
    };
    users.users.guacd = { isSystemUser = true; group = "guacd"; };
    users.groups.guacd = { };

    networking.firewall.allowedTCPPorts = [ cfg.port cfg.guacd.port ];

    systemd.services.rustguac.wantedBy = [ "multi-user.target" ];
    systemd.services.guacd.wantedBy = [ "multi-user.target" ];
  };
}