{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustguac;

  # Binaire pre-built de la release GitHub (rustguac n'est pas dans nixpkgs).
  # PIEGE : la release est une ARCHIVE COMPLETE (bin/, static/, lib/, sbin/,
  # scripts/, config.toml.default). L'ancienne installPhase ne copiait que
  # bin/rustguac, donc l'UI web (static/) manquait et le serveur n'avait aucune
  # page a servir.
  rustguacPackage = pkgs.stdenv.mkDerivation {
    pname = "rustguac";
    version = "1.10.0";

    src = pkgs.fetchurl {
      url = "https://github.com/sol1/rustguac/releases/download/v1.10.0/rustguac-1.10.0-linux-amd64.tar.gz";
      sha256 = "sha256-z9MPBTpb/qWby9KYT3ELSisy06mbvfIE/VSpmcsIuQg=";
    };

    # stdenv a deja deballe l'archive ET s'est place dans son unique dossier
    # racine (sourceRoot) : il suffit de reprendre l'arbre courant tel quel.
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

  # Le role_id vient du bootstrap Vault (fichier ecrit a l'execution) : la
  # section [vault] ne peut donc pas etre figee dans le store. Le wrapper la
  # colle au config.toml au demarrage et exporte le secret_id via
  # VAULT_SECRET_ID (le seul chemin documente par rustguac : role_id en config,
  # secret_id en env).
  runScript = pkgs.writeShellApplication {
    name = "rustguac-run";
    runtimeInputs = [ rustguacPackage pkgs.coreutils ];
    text = ''
      set -euo pipefail
      conf="''${RUSTGUAC_RUNTIME_DIR:?}/config.toml"
      # `cat > fichier` et pas `cp` : cp recopie AUSSI le mode du fichier du
      # store (0444), et le `>>` d'ajout de la section [vault] juste apres
      # echouait en « Permission denied » (le fichier venait d'etre cree en
      # lecture seule).
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

  # rustguac n'accepte PAS un simple token Vault : il lui faut role_id (config)
  # + secret_id (env VAULT_SECRET_ID), donc une auth AppRole. Le token root ne
  # sert qu'a creer la policy, le role, et a sortir ces deux valeurs.
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
      echo "rustguac: AppRole ${cfg.vault.roleName} pret (role_id/secret_id sous ${stateDir})"
    '';
  };

  # Schema REEL de rustguac 1.10.0 (src/config.rs) : listen_addr / guacd_addr /
  # static_path / db_path / rate_limit / trusted_proxies sont des cles RACINE
  # (pas de section [server] ni [guacd]), [oidc] attend redirect_uri +
  # extra_scopes + default_role, [recording] attend path, et le TLS guacd
  # s'exprime par [tls] guacd_cert_path (pas un booleen).
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
      description = "Adresse d'ecoute (listen_addr)";
    };
    port = mkOption {
      type = types.port;
      default = 8089;
      description = "Port HTTP de rustguac";
    };

    dbPath = mkOption {
      type = types.str;
      default = "${stateDir}/rustguac.db";
      description = "Base sqlite (admins, utilisateurs OIDC, sessions)";
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
      description = "HTTPS cote client (null = HTTP derriere un reverse proxy)";
    };

    guacd = mkOption {
      type = types.submodule {
        options = {
          host = mkOption { type = types.str; default = "127.0.0.1"; };
          port = mkOption { type = types.port; default = 4822; };
          # guacd n'a pas de drapeau "activer TLS" : il sert du TLS des qu'on lui
          # donne -C certificat -K cle. rustguac de son cote ne parle TLS que si
          # [tls] guacd_cert_path est renseigne. Les deux doivent etre d'accord.
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
            description = "Fichier contenant le token root, lu par le bootstrap (root)";
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
      description = "Address book Vault (AppRole). null = pas d'address book.";
    };

    oidc = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          issuerUrl = mkOption { type = types.str; };
          clientId = mkOption { type = types.str; };
          # Valeur LITTERALE. Pour un secret qui vit dans un fichier sops,
          # utiliser clientSecretFile : il est exporte en OIDC_CLIENT_SECRET et
          # n'apparait jamais dans la config (le chemin, lui, ne marcherait pas).
          clientSecret = mkOption { type = types.nullOr types.str; default = null; };
          clientSecretFile = mkOption { type = types.nullOr types.path; default = null; };
          redirectUri = mkOption {
            type = types.str;
            description = "URL publique + /auth/callback (chemin rustguac)";
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
      description = "OIDC (null = desactive, auth par cle API seulement)";
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
      description = "Limitation de debit cote rustguac (inutile derriere un reverse proxy)";
    };

    trustedProxies = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1/32" ];
      description = "CIDR des proxys dont X-Forwarded-For est digne de confiance";
    };

    user = mkOption { type = types.str; default = "rustguac"; };
    group = mkOption { type = types.str; default = "rustguac"; };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.guacd.tls || (cfg.guacd.certFile != null && cfg.guacd.keyFile != null);
        message = "services.rustguac.guacd.tls = true exige guacd.certFile et guacd.keyFile (guacd n'a pas de drapeau TLS sans certificat).";
      }
      {
        assertion = cfg.vault == null || (cfg.vault.roleIdFile == "${stateDir}/role-id" && cfg.vault.secretIdFile == "${stateDir}/secret-id");
        message = "services.rustguac.vault.roleIdFile/secretIdFile doivent rester sous ${stateDir} (le service les relit au demarrage).";
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
        # le bootstrap tourne en root (+) : il lit le token root et ecrit
        # role-id/secret-id dans ${stateDir}, que le service relit ensuite.
        ExecStartPre = optional (cfg.vault != null) "+${vaultBootstrap}/bin/rustguac-vault-bootstrap";
        Environment = [
          "RUST_LOG=info"
          "RUSTGUAC_RUNTIME_DIR=/run/rustguac"
        ];
        ExecStart = "${runScript}/bin/rustguac-run";
        # systemd cree /run/rustguac en tant que service user : un tmpfiles
        # « d /run/rustguac ... rustguac » ne suffisait pas (le repertoire existait
        # deja en root, d'ou « Permission denied » sur le cp du config au demarrage).
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
        # CLI reelle de guacd : -b ADRESSE, -l PORT, -p PIDFILE, -L NIVEAU_DE_LOG,
        # -C certificat, -K cle, -f (premier plan). L'ancienne ligne
        # « -L 127.0.0.1 -p 4822 -t » etait fausse sur les trois drapeaux
        # (-L attend un niveau de log, -p un pidfile, -t n'existe pas) : guacd
        # sortait immediatement en « Invalid log level ».
        ExecStart = "${guacdPackage}/sbin/guacd -f -b ${cfg.guacd.host} -l ${toString cfg.guacd.port}"
          + optionalString cfg.guacd.tls " -C ${cfg.guacd.certFile} -K ${cfg.guacd.keyFile}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    users.users.guacd = { isSystemUser = true; group = "guacd"; };
    users.groups.guacd = { };

    # rustguac et guacd ecoutent en loopback (host par defaut) et sont atteints
    # via le vhost nginx : rien a ouvrir au firewall.
  };
}
