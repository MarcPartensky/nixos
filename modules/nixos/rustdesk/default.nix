{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustdesk;
in {

  options.services.rustdesk = {
    enable = mkEnableOption "RustDesk server (hbbs + hbbr)";

    # La CLI de rustdesk-server 1.1.16 n'a que : hbbs -p <port id/rendezvous>,
    # -r <relais>, -k <cle>, -R, -M, -s, -u ; hbbr -p <port relais>, -k <cle>.
    # Il n'y a NI -i (bind) NI -a (autre port) : passer ces drapeaux fait sortir
    # le binaire en « Found argument '-i' which wasn't expected ».
    # hbbs se lie tout seul sur 21115 (test NAT) / 21116 (ID, TCP+UDP) /
    # 21118 (websocket), hbbr sur 21117 (relais) et 21119 (websocket).
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
            description = "Relais annonces aux clients (-r), virgule-separes";
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
            description = "Port relais (TCP)";
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
        # hbbs ecrit sa paire de cles dans le repertoire courant quand -k n'est
        # pas fourni : sans WorkingDirectory il tente d'ecrire dans / et sort en
        # erreur (le service sortait en status=1 avant meme de se lier).
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

    # Ports reels des deux binaires (pas de drapeau pour les deplacer) :
    # 21115 test NAT, 21116 ID TCP+UDP, 21117 relais, 21118/21119 websocket.
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall ([ 21115 21116 21117 21118 21119 ]);
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ 21116 ];
  };
}