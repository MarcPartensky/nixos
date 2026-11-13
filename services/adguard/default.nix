{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.dnsFilter;
in {
  options.services.dnsFilter = {
    enable = lib.mkEnableOption "AdGuard Home comme résolveur filtrant du tailnet"
      // {
        default = true;
        description = ''
          Actif par défaut : importer ce module (directement, ou via
          services/default.nix pour tower et le laptop) suffit à faire tourner
          le résolveur. Se désactive au cas par cas avec `enable = false`.
        '';
      };

    webHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Adresse d'écoute de l'UI d'admin AdGuard.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port de l'UI d'admin AdGuard.";
    };

    bindHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["0.0.0.0"];
      description = ''
        Adresses d'écoute du résolveur DNS. 0.0.0.0 et pas l'IP mesh en dur :
        l'unité n'a pas de Restart= et l'IP tailscale peut ne pas être
        attribuée au boot. tailscale0 est dans trustedInterfaces et le 53 n'est
        jamais ouvert au firewall, donc le bind large reste confiné au mesh (et
        à la loopback de la machine).
      '';
    };

    openWebPort = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Ouvre webPort au firewall (inutile quand webHost est en loopback).";
    };

    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["1.1.1.1"];
      description = "Résolveurs de secours de la machine elle-même (pas ceux poussés au tailnet).";
    };

    upstreamDns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://dns.cloudflare.com/dns-query"
        "https://dns.quad9.net/dns-query"
      ];
      description = "Amonts DoH d'AdGuard : ils décident de ce que le filtrage laisse passer.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      host = cfg.webHost;
      port = cfg.webPort;
      mutableSettings = false; # régénère le YAML et nettoie les clés parasites
      settings = {
        dns = {
          bind_hosts = cfg.bindHosts;
          port = 53;
          upstream_dns = cfg.upstreamDns;
          bootstrap_dns = ["1.1.1.1" "9.9.9.9"];
          cache_size = 4194304;
          ratelimit = 0;
          blocked_response_ttl = 60;
          protection_enabled = true;
          filtering_enabled = true;
          safe_search.enabled = false;
        };
        querylog.enabled = false;
        statistics = {
          enabled = true;
          interval = "24h";
        };
        filters = [
          {
            enabled = true;
            id = 1;
            name = "AdGuard DNS filter";
            url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt";
          }
        ];
      };
    };

    networking.nameservers = cfg.nameservers;
    networking.networkmanager.dns = lib.mkIf config.networking.networkmanager.enable "none";
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openWebPort [cfg.webPort];
  };
}
