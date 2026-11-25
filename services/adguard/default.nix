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
      default = ["127.0.0.1"];
      description = ''
        Adresses d'écoute du résolveur DNS. NE JAMAIS remettre "0.0.0.0" : un
        bind joker sur le 53/UDP échoue dès qu'une adresse PRÉCISE tient déjà
        le port, et c'est le cas des passerelles de réseaux podman
        (aardvark-dns écoute sur le 53 de 10.88.0.1, 10.89.0.1, 10.89.1.1).
        Mesuré le 14/11/2026 sur tower : 2300 redémarrages d'affilée sur
        « listen udp 0.0.0.0:53: bind: address already in use », donc zéro
        résolution sur 127.0.0.1:53 comme sur 100.64.0.3:53 pendant des
        semaines, alors que la configuration semblait bonne. Chaque hôte du
        tailnet ajoute donc explicitement SON adresse 100.64.x.y dans son
        profil ; le service a Restart=always et retente jusqu'à ce que
        tailscale0 porte son IP (il est aussi ordonné après tailscaled).
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

    extraRewrites = lib.mkOption {
      type = lib.types.listOf (lib.types.attrs);
      default = [ ];
      example = [ { domain = "mesh"; answer = "100.64.0.3"; } ];
      description = ''
        Réécritures DNS servies par cette instance (réponses statiques). Sert à
        faire résoudre un nom court comme `mesh` sans search domain, y compris
        sur les appareils qui ne peuvent pas éditer /etc/hosts (Android).
      '';
    };

    upstreamDns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://dns.cloudflare.com/dns-query"
        "https://dns.quad9.net/dns-query"
      ];
      description = "Amonts DoH d'AdGuard : ils décident de ce que le filtrage laisse passer.";
    };

    filters = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [
        {
          name = "AdGuard DNS filter";
          url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt";
          enabled = true;
        }
      ];
      example = [
        {
          name = "HaGeZi Pro";
          url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt";
        }
      ];
      description = ''
        Abonnements de filtrage, par (nom, url). AdGuard les retélécharge toutes
        les 24 h : rien n'est épinglé dans le store, et une liste mise à jour en
        amont arrive sans rebuild. Les `id` sont attribués par position.

        Coût mesuré sur tower (0.107.79, même binaire, instance isolée) :
        liste de base seule 57 Mo de RSS / 2,5 Mo de disque ; + HaGeZi Pro 96 Mo ;
        + TIF medium 263 Mo ; + Fake 357 Mo / 11 Mo. La RAM est le vrai coût, pas
        le disque : les listes de menaces (domaines très longs) pèsent ~470 octets
        de RSS par règle, contre ~120 pour une liste de pubs. D'où un défaut
        volontairement minimal : chaque hôte ajoute ce qu'il peut porter.
      '';
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
        # Reponses statiques : noms courts du proxy interne (le service est sur
        # tower, d'ou l'IP mesh). Sans ca, `mesh` ne resout que la ou un
        # /etc/hosts a ete pose.
        filtering = lib.mkIf (cfg.extraRewrites != [ ]) {
          rewrites = cfg.extraRewrites;
        };
        statistics = {
          enabled = true;
          interval = "24h";
        };
        filters = lib.imap0 (
          i: f:
          f
          // {
            id = if f ? id then f.id else i + 1;
            # Un filtre sans `enabled` explicite est écrit `enabled: false`
            # par AdGuard, donc présent mais inerte (symptôme : rules_count 0).
            enabled = if f ? enabled then f.enabled else true;
          }
        ) cfg.filters;
      };
    };

    # L'adresse 100.64.x.y de tailscale0 n'existe pas forcément au boot : sans
    # cet ordre, AdGuard boucle une dizaine de fois avant que tailscaled ne
    # publie l'IP (il finit par démarrer, Restart=always, mais bruyamment).
    systemd.services.adguardhome = {
      after = ["tailscaled.service"];
      wants = ["tailscaled.service"];
    };

    networking.nameservers = cfg.nameservers;
    networking.networkmanager.dns = lib.mkIf config.networking.networkmanager.enable "none";
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openWebPort [cfg.webPort];
  };
}
