{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustdesk;
in {

  options.services.rustdesk = {
    enable = mkEnableOption "RustDesk server (hbbs + hbbr)";

    hbbs = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          host = mkOption { type = types.str; default = "0.0.0.0"; };
          port = mkOption { type = types.port; default = 21115; };
          keyPath = mkOption { type = types.nullOr types.path; default = null; };
        };
      };
      default = { enable = true; };
    };

    hbbr = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          host = mkOption { type = types.str; default = "0.0.0.0"; };
          port = mkOption { type = types.port; default = 21116; };
          apiPort = mkOption { type = types.port; default = 21118; };
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
        ExecStart = "${pkgs.rustdesk-server}/bin/hbbs -i ${cfg.hbbs.host} -p ${toString cfg.hbbs.port}" + (if cfg.hbbs.keyPath != null then " -k ${cfg.hbbs.keyPath}" else "");
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
        ExecStart = "${pkgs.rustdesk-server}/bin/hbbr -i ${cfg.hbbr.host} -p ${toString cfg.hbbr.port} -a ${cfg.hbbr.host}:${toString cfg.hbbr.apiPort}";
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

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall
      ([ cfg.hbbs.port ] ++ [ cfg.hbbr.port cfg.hbbr.apiPort ] ++ lib.optionals cfg.dashboard.enable [ cfg.dashboard.port ]);
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ cfg.hbbs.port cfg.hbbr.port ];
  };
}