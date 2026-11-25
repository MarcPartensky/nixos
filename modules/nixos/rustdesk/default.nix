{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustdesk;
in {

  options.services.rustdesk = {
    enable = mkEnableOption "RustDesk server (hbbs + hbbr)";

    # The rustdesk-server 1.1.16 CLI only has: hbbs -p <id/rendezvous port>,
    # -r <relay>, -k <key>, -R, -M, -s, -u ; hbbr -p <relay port>, -k <key>.
    # There is NEITHER -i (bind) NOR -a (other port): passing these flags makes
    # the binary exit with "Found argument '-i' which wasn't expected".
    # hbbs binds by itself on 21115 (NAT test) / 21116 (ID, TCP+UDP) /
    # 21118 (websocket), hbbr on 21117 (relay) and 21119 (websocket).
    hbbs = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          idPort = mkOption {
            type = types.port;
            default = 21116;
            description = "Port ID/rendezvous (TCP+UDP)";
          };
          relayServers = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Relay servers advertised to clients (-r), comma-separated";
          };
          keyPath = mkOption { type = types.nullOr types.path; default = null; };
        };
      };
      default = { enable = true; };
    };

    hbbr = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          port = mkOption {
            type = types.port;
            default = 21117;
            description = "Relay port (TCP)";
          };
          keyPath = mkOption { type = types.nullOr types.path; default = null; };
        };
      };
      default = { enable = true; };
    };

    dashboard = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = false; };
          port = mkOption { type = types.port; default = 21114; };
        };
      };
      default = { enable = false; };
    };

    openFirewall = mkOption { type = types.bool; default = true; };

    user = mkOption { type = types.str; default = "rustdesk"; };
    group = mkOption { type = types.str; default = "rustdesk"; };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/rustdesk";
      description = "RustDesk service user";
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d /var/lib/rustdesk 0750 ${cfg.user} ${cfg.group} - -"
    ];

    # hbbs service
    systemd.services.rustdesk-hbbs = mkIf cfg.hbbs.enable {
      description = "RustDesk hbbs (rendezvous/id server)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        # hbbs writes its key pair into the current directory when -k is not
        # provided: without WorkingDirectory it tries to write to / and exits
        # with an error (the service exited with status=1 even before binding).
        WorkingDirectory = "/var/lib/rustdesk";
        ExecStart = "${pkgs.rustdesk-server}/bin/hbbs -p ${toString cfg.hbbs.idPort}"
          + optionalString (cfg.hbbs.relayServers != null) " -r ${cfg.hbbs.relayServers}"
          + optionalString (cfg.hbbs.keyPath != null) " -k ${cfg.hbbs.keyPath}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # hbbr service
    systemd.services.rustdesk-hbbr = mkIf cfg.hbbr.enable {
      description = "RustDesk hbbr (relay server)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/var/lib/rustdesk";
        ExecStart = "${pkgs.rustdesk-server}/bin/hbbr -p ${toString cfg.hbbr.port}"
          + optionalString (cfg.hbbr.keyPath != null) " -k ${cfg.hbbr.keyPath}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Dashboard (if enabled)
    systemd.services.rustdesk-dashboard = mkIf cfg.dashboard.enable {
      description = "RustDesk web dashboard";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${pkgs.rustdesk-server}/bin/hbbs -w ${toString cfg.dashboard.port}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Real ports of the two binaries (no flag to move them):
    # 21115 NAT test, 21116 ID TCP+UDP, 21117 relay, 21118/21119 websocket.
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall ([ 21115 21116 21117 21118 21119 ]);
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ 21116 ];
  };
}