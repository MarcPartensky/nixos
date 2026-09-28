{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.vault-rustguac;
in {

  options.services.vault-rustguac = {
    enable = mkEnableOption "Vault - Secret management (dev mode for testing)";

    # Mode: "dev" (in-memory, auto-unseal) or "ha" (Raft, persistent)
    mode = mkOption {
      type = types.enum [ "dev" "ha" ];
      default = "dev";
      description = "Vault mode: dev (testing) or ha (production Raft)";
    };

    # Network
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address";
    };
    port = mkOption {
      type = types.port;
      default = 8200;
      description = "HTTP/HTTPS port";
    };

    # TLS (dev mode can use HTTP)
    tls = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          certFile = mkOption { type = types.path; };
          keyFile = mkOption { type = types.path; };
        };
      });
      default = null;
    };

    # Dev mode settings
    devRootToken = mkOption {
      type = types.str;
      default = "root-token-dev-only";
      description = "Root token for dev mode (CHANGE IN PROD!)";
    };

    # HA/Raft settings
    ha = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          clusterName = mkOption { type = types.str; default = "vault-cluster"; };
          dataPath = mkOption { type = types.path; default = "/var/lib/vault"; };
          nodeId = mkOption { type = types.str; default = "node1"; };
          apiAddr = mkOption { type = types.str; default = "https://127.0.0.1:8200"; };
          clusterAddr = mkOption { type = types.str; default = "https://127.0.0.1:8201"; };
          retryJoin = mkOption { type = types.listOf types.str; default = [ ]; };
        };
      });
      default = null;
    };

    # User/group
    user = mkOption { type = types.str; default = "vault"; };
    group = mkOption { type = types.str; default = "vault"; };

    # UI
    ui = mkOption { type = types.bool; default = true; };
  };

  config = mkIf cfg.enable {
    # User/group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/vault";
      description = "Vault service user";
    };
    users.groups.${cfg.group} = { };

    # Directories
    systemd.tmpfiles.rules = [
      "d /var/lib/vault 0750 ${cfg.user} ${cfg.group} - -"
      "d /etc/vault 0750 ${cfg.user} ${cfg.group} - -"
    ];

    # Config
    environment.etc."vault/config.hcl".text = ''
      ${if cfg.mode == "dev" then ''
      storage "inmem" {}

      listener "tcp" {
        address = "${cfg.address}:${toString cfg.port}"
        ${if cfg.tls != null then ''
        tls_cert_file = "${cfg.tls.certFile}"
        tls_key_file = "${cfg.tls.keyFile}"
        '' else "tls_disable = true"}
      }

      dev_root_token_id = "${cfg.devRootToken}"
      dev_listen_address = "${cfg.address}:${toString cfg.port}"
      '' else ''
      storage "raft" {
        path = "${cfg.ha.dataPath}"
        node_id = "${cfg.ha.nodeId}"
        ${concatStringsSep "\n        " (map (addr: "retry_join { leader_api_addr = \"${addr}\" }") cfg.ha.retryJoin)}
      }

      listener "tcp" {
        address = "${cfg.address}:${toString cfg.port}"
        ${if cfg.tls != null then ''
        tls_cert_file = "${cfg.tls.certFile}"
        tls_key_file = "${cfg.tls.keyFile}"
        '' else "tls_disable = true"}
      }

      cluster_addr = "${cfg.ha.clusterAddr}"
      api_addr = "${cfg.ha.apiAddr}"
      ''}

      ui = ${toString cfg.ui}
      disable_mlock = true
    '';

    # Systemd service
    systemd.services.vault = {
      description = "Vault - Secret management";
      after = [ "network.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${pkgs.vault}/bin/vault server -config /etc/vault/config.hcl";
        Restart = "on-failure";
        RestartSec = 5;
        LimitNOFILE = 65536;
        Environment = "VAULT_ADDR=${if cfg.tls != null then "https" else "http"}://${cfg.address}:${toString cfg.port}";
        # For mlock (disabled in config)
        CapabilityBoundingSet = "CAP_IPC_LOCK";
      };
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Auto-unseal for dev mode (already unsealed)
    # For HA, you'd need to run: vault operator init && vault operator unseal

    systemd.services.vault.wantedBy = [ "multi-user.target" ];
  };
}