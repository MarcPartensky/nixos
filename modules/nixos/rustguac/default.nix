{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustguac;

  # Pre-built binary from the GitHub release (rustguac is not in nixpkgs).
  # PITFALL: the release is a COMPLETE ARCHIVE (bin/, static/, lib/, sbin/,
  # scripts/, config.toml.default). The old installPhase copied only
  # bin/rustguac, so the web UI (static/) was missing and the server had no
  # page to serve.
  rustguacPackage = pkgs.stdenv.mkDerivation {
    pname = "rustguac";
    version = "1.10.0";

    src = pkgs.fetchurl {
      url = "https://github.com/sol1/rustguac/releases/download/v1.10.0/rustguac-1.10.0-linux-amd64.tar.gz";
      sha256 = "sha256-z9MPBTpb/qWby9KYT3ELSisy06mbvfIE/VSpmcsIuQg=";
    };

    # stdenv has already unpacked the archive AND moved into its single
    # root folder (sourceRoot): it is enough to reuse the current tree as-is.
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a ./. $out/
      rm -rf $out/install.sh $out/systemd $out/config.toml.default
      runHook postInstall
    '';
  };

  guacdPackage = pkgs.guacamole-server;

  stateDir = "/var/lib/rustguac";

  # The role_id comes from the Vault bootstrap (file written at runtime): the
  # [vault] section therefore cannot be frozen in the store. The wrapper
  # appends it to config.toml at startup and exports the secret_id via
  # VAULT_SECRET_ID (the only path documented by rustguac: role_id in config,
  # secret_id in env).
  runScript = pkgs.writeShellApplication {
    name = "rustguac-run";
    runtimeInputs = [ rustguacPackage pkgs.coreutils ];
    text = ''
      set -euo pipefail
      conf="''${RUSTGUAC_RUNTIME_DIR:?}/config.toml"
      # `cat > file` and not `cp`: cp ALSO copies the mode of the store
      # file (0444), and the `>>` appending the [vault] section just after
      # failed with "Permission denied" (the file had just been created
      # read-only).
      cat ${configFile} > "$conf"
      ${optionalString (cfg.oidc != null && cfg.oidc.clientSecretFile != null) ''
        OIDC_CLIENT_SECRET="$(cat ${cfg.oidc.clientSecretFile})"
        export OIDC_CLIENT_SECRET
      ''}
      ${optionalString (cfg.vault != null) ''
        VAULT_ADDR="${cfg.vault.address}"
        VAULT_SECRET_ID="$(cat ${cfg.vault.secretIdFile})"
        export VAULT_ADDR VAULT_SECRET_ID
        {
          echo ""
          echo "[vault]"
          echo "addr = \"${cfg.vault.address}\""
          echo "mount = \"${cfg.vault.mountPath}\""
          echo "base_path = \"${cfg.vault.basePath}\""
          echo "role_id = \"$(cat ${cfg.vault.roleIdFile})\""
          ${optionalString (cfg.vault.instanceName != null) ''
            echo "instance_name = \"${cfg.vault.instanceName}\""
          ''}
        } >> "$conf"
      ''}
      exec rustguac --config "$conf" serve
    '';
  };

  # rustguac does NOT accept a plain Vault token: it needs role_id (config)
  # + secret_id (env VAULT_SECRET_ID), so an AppRole auth. The root token
  # only serves to create the policy, the role, and to output these two values.
  vaultBootstrap = pkgs.writeShellApplication {
    name = "rustguac-vault-bootstrap";
    runtimeInputs = [ pkgs.vault pkgs.coreutils ];
    text = ''
      set -euo pipefail
      VAULT_ADDR="${cfg.vault.address}"
      VAULT_TOKEN="$(cat ${cfg.vault.rootTokenFile})"
      export VAULT_ADDR VAULT_TOKEN
      install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${stateDir}

      vault auth enable approle 2>/dev/null || true
      vault policy write rustguac - >/dev/null <<'POLICY'
      path "${cfg.vault.mountPath}/data/${cfg.vault.basePath}/*" {
        capabilities = ["create", "read", "update", "delete", "list"]
      }
      path "${cfg.vault.mountPath}/metadata/${cfg.vault.basePath}/*" {
        capabilities = ["read", "list", "delete"]
      }
      POLICY
      vault write "auth/approle/role/${cfg.vault.roleName}" \
        token_policies=rustguac \
        token_ttl=1h token_max_ttl=24h \
        secret_id_ttl=0 bind_secret_id=true >/dev/null

      umask 077
      vault read -field=role_id "auth/approle/role/${cfg.vault.roleName}/role-id" > ${cfg.vault.roleIdFile}
      vault write -f -field=secret_id "auth/approle/role/${cfg.vault.roleName}/secret-id" > ${cfg.vault.secretIdFile}
      chown ${cfg.user}:${cfg.group} ${cfg.vault.roleIdFile} ${cfg.vault.secretIdFile}
      chmod 0400 ${cfg.vault.roleIdFile} ${cfg.vault.secretIdFile}
      echo "rustguac: AppRole ${cfg.vault.roleName} ready (role_id/secret_id under ${stateDir})"
    '';
  };

  # REAL schema of rustguac 1.10.0 (src/config.rs): listen_addr / guacd_addr /
  # static_path / db_path / rate_limit / trusted_proxies are ROOT keys
  # (no [server] or [guacd] section), [oidc] expects redirect_uri +
  # extra_scopes + default_role, [recording] expects path, and guacd TLS
  # is expressed by [tls] guacd_cert_path (not a boolean).
  configFile = pkgs.writeText "rustguac-config.toml" ''
    listen_addr = "${cfg.host}:${toString cfg.port}"
    guacd_addr = "${cfg.guacd.host}:${toString cfg.guacd.port}"
    recording_path = "${cfg.recording.path}"
    static_path = "${rustguacPackage}/static"
    db_path = "${cfg.dbPath}"
    site_title = "${cfg.siteTitle}"
    rate_limit = ${boolToString cfg.rateLimit}
    trusted_proxies = [${concatStringsSep ", " (map (p: "\"${p}\"") cfg.trustedProxies)}]
    ${optionalString (cfg.tls != null) ''
      [tls]
      cert_path = "${cfg.tls.certFile}"
      key_path = "${cfg.tls.keyFile}"
      ${optionalString cfg.guacd.tls ''guacd_cert_path = "${cfg.guacd.certFile}"''}
    ''}
    ${optionalString (cfg.tls == null && cfg.guacd.tls) ''
      [tls]
      guacd_cert_path = "${cfg.guacd.certFile}"
    ''}
    ${optionalString (cfg.oidc != null) ''
      [oidc]
      issuer_url = "${cfg.oidc.issuerUrl}"
      client_id = "${cfg.oidc.clientId}"
      ${optionalString (cfg.oidc.clientSecret != null) ''client_secret = "${cfg.oidc.clientSecret}"''}
      redirect_uri = "${cfg.oidc.redirectUri}"
      default_role = "${cfg.oidc.defaultRole}"
      groups_claim = "${cfg.oidc.groupsClaim}"
      ${optionalString (cfg.oidc.extraScopes != [ ]) ''extra_scopes = [${concatStringsSep ", " (map (s: "\"${s}\"") cfg.oidc.extraScopes)}]''}
    ''}
    [recording]
    enabled = ${boolToString cfg.recording.enable}
    path = "${cfg.recording.path}"
    max_disk_percent = ${toString cfg.recording.maxDiskPercent}
    max_recordings = ${toString cfg.recording.maxRecordings}
  '';
in {

  options.services.rustguac = {
    enable = mkEnableOption "rustguac - Lightweight Rust replacement for Apache Guacamole";

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address (listen_addr)";
    };
    port = mkOption {
      type = types.port;
      default = 8089;
      description = "rustguac HTTP port";
    };

    dbPath = mkOption {
      type = types.str;
      default = "${stateDir}/rustguac.db";
      description = "sqlite database (admins, OIDC users, sessions)";
    };
    siteTitle = mkOption { type = types.str; default = "rustguac"; };

    tls = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          certFile = mkOption { type = types.path; };
          keyFile = mkOption { type = types.path; };
        };
      });
      default = null;
      description = "HTTPS client-side (null = HTTP behind a reverse proxy)";
    };

    guacd = mkOption {
      type = types.submodule {
        options = {
          host = mkOption { type = types.str; default = "127.0.0.1"; };
          port = mkOption { type = types.port; default = 4822; };
          # guacd has no "enable TLS" flag: it serves TLS as soon as it is
          # given -C certificate -K key. rustguac for its part speaks TLS only if
          # [tls] guacd_cert_path is set. Both must agree.
          tls = mkOption { type = types.bool; default = false; };
          certFile = mkOption { type = types.nullOr types.path; default = null; };
          keyFile = mkOption { type = types.nullOr types.path; default = null; };
        };
      };
      default = { host = "127.0.0.1"; port = 4822; tls = false; };
    };

    vault = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          address = mkOption { type = types.str; default = "http://127.0.0.1:8200"; };
          rootTokenFile = mkOption {
            type = types.path;
            description = "File containing the root token, read by the bootstrap (root)";
          };
          mountPath = mkOption { type = types.str; default = "secret"; };
          basePath = mkOption { type = types.str; default = "rustguac"; };
          instanceName = mkOption { type = types.nullOr types.str; default = null; };
          roleName = mkOption { type = types.str; default = "rustguac"; };
          roleIdFile = mkOption { type = types.str; default = "${stateDir}/role-id"; };
          secretIdFile = mkOption { type = types.str; default = "${stateDir}/secret-id"; };
        };
      });
      default = null;
      description = "Vault address book (AppRole). null = no address book.";
    };

    oidc = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          issuerUrl = mkOption { type = types.str; };
          clientId = mkOption { type = types.str; };
          # LITERAL value. For a secret that lives in a sops file,
          # use clientSecretFile: it is exported as OIDC_CLIENT_SECRET and
          # never appears in the config (the path, for its part, would not work).
          clientSecret = mkOption { type = types.nullOr types.str; default = null; };
          clientSecretFile = mkOption { type = types.nullOr types.path; default = null; };
          redirectUri = mkOption {
            type = types.str;
            description = "Public URL + /auth/callback (rustguac path)";
          };
          defaultRole = mkOption {
            type = types.enum [ "admin" "poweruser" "operator" "viewer" ];
            default = "operator";
          };
          groupsClaim = mkOption { type = types.str; default = "groups"; };
          extraScopes = mkOption { type = types.listOf types.str; default = [ ]; };
        };
      });
      default = null;
      description = "OIDC (null = disabled, API key auth only)";
    };

    recording = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          path = mkOption { type = types.str; default = "${stateDir}/recordings"; };
          maxDiskPercent = mkOption { type = types.int; default = 80; };
          maxRecordings = mkOption { type = types.int; default = 0; };
        };
      };
      default = { };
    };

    rateLimit = mkOption {
      type = types.bool;
      default = false;
      description = "Rate limiting on the rustguac side (useless behind a reverse proxy)";
    };

    trustedProxies = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1/32" ];
      description = "CIDR of the proxies whose X-Forwarded-For is trustworthy";
    };

    user = mkOption { type = types.str; default = "rustguac"; };
    group = mkOption { type = types.str; default = "rustguac"; };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.guacd.tls || (cfg.guacd.certFile != null && cfg.guacd.keyFile != null);
        message = "services.rustguac.guacd.tls = true requires guacd.certFile and guacd.keyFile (guacd has no TLS flag without a certificate).";
      }
      {
        assertion = cfg.vault == null || (cfg.vault.roleIdFile == "${stateDir}/role-id" && cfg.vault.secretIdFile == "${stateDir}/secret-id");
        message = "services.rustguac.vault.roleIdFile/secretIdFile must stay under ${stateDir} (the service rereads them at startup).";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = stateDir;
      description = "rustguac service user";
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.recording.path} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    environment.etc."rustguac/config.toml".source = configFile;

    systemd.services.rustguac = {
      description = "rustguac - Lightweight Rust replacement for Apache Guacamole";
      after = [ "network.target" ] ++ optional (cfg.vault != null) "vault.service";
      wants = optional (cfg.vault != null) "vault.service";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = stateDir;
        # the bootstrap runs as root (+): it reads the root token and writes
        # role-id/secret-id into ${stateDir}, which the service rereads afterwards.
        ExecStartPre = optional (cfg.vault != null) "+${vaultBootstrap}/bin/rustguac-vault-bootstrap";
        Environment = [
          "RUST_LOG=info"
          "RUSTGUAC_RUNTIME_DIR=/run/rustguac"
        ];
        ExecStart = "${runScript}/bin/rustguac-run";
        # systemd creates /run/rustguac as the service user: a tmpfiles
        # "d /run/rustguac ... rustguac" was not enough (the directory already
        # existed as root, hence "Permission denied" on the cp of the config at startup).
        RuntimeDirectory = "rustguac";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = 5;
        LimitNOFILE = 65536;
      };
    };

    systemd.services.guacd = {
      description = "guacd - Guacamole proxy daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "guacd";
        Group = "guacd";
        # Real guacd CLI: -b ADDRESS, -l PORT, -p PIDFILE, -L LOG_LEVEL,
        # -C certificate, -K key, -f (foreground). The old line
        # "-L 127.0.0.1 -p 4822 -t" was wrong on all three flags
        # (-L expects a log level, -p a pidfile, -t does not exist): guacd
        # exited immediately with "Invalid log level".
        ExecStart = "${guacdPackage}/sbin/guacd -f -b ${cfg.guacd.host} -l ${toString cfg.guacd.port}"
          + optionalString cfg.guacd.tls " -C ${cfg.guacd.certFile} -K ${cfg.guacd.keyFile}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    users.users.guacd = { isSystemUser = true; group = "guacd"; };
    users.groups.guacd = { };

    # rustguac and guacd listen on loopback (default host) and are reached
    # via the nginx vhost: nothing to open at the firewall.
  };
}
