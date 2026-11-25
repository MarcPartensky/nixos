{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.dnsFilter;
in {
  options.services.dnsFilter = {
    enable = lib.mkEnableOption "AdGuard Home as the tailnet's filtering resolver"
      // {
        default = true;
        description = ''
          Active by default: importing this module (directly, or via
          services/default.nix for tower and the laptop) is enough to run
          the resolver. Disabled on a per-case basis with `enable = false`.
        '';
      };

    webHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listen address of the AdGuard admin UI.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port of the AdGuard admin UI.";
    };

    bindHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["127.0.0.1"];
      description = ''
        Listen addresses of the DNS resolver. NEVER put back "0.0.0.0": a
        wildcard bind on 53/UDP fails as soon as a SPECIFIC address already holds
        the port, and that is the case for the gateways of podman networks
        (aardvark-dns listens on port 53 of 10.88.0.1, 10.89.0.1, 10.89.1.1).
        Measured on 14/11/2026 on tower: 2300 restarts in a row on
        "listen udp 0.0.0.0:53: bind: address already in use", so zero
        resolution on 127.0.0.1:53 as well as 100.64.0.3:53 for
        weeks, while the configuration looked correct. Each host of the
        tailnet therefore explicitly adds ITS 100.64.x.y address in its
        profile; the service has Restart=always and retries until
        tailscale0 carries its IP (it is also ordered after tailscaled).
      '';
    };

    openWebPort = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open webPort in the firewall (useless when webHost is on loopback).";
    };

    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["1.1.1.1"];
      description = "Fallback resolvers of the machine itself (not the ones pushed to the tailnet).";
    };

    extraRewrites = lib.mkOption {
      type = lib.types.listOf (lib.types.attrs);
      default = [ ];
      example = [ { domain = "mesh"; answer = "100.64.0.3"; } ];
      description = ''
        DNS rewrites served by this instance (static answers). Used to
        resolve a short name like `mesh` without a search domain, including
        on devices that cannot edit /etc/hosts (Android).
      '';
    };

    upstreamDns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://dns.cloudflare.com/dns-query"
        "https://dns.quad9.net/dns-query"
      ];
      description = "AdGuard's DoH upstreams: they decide what the filtering lets through.";
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
        Filtering subscriptions, by (name, url). AdGuard re-downloads them every
        24 h: nothing is pinned in the store, and a list updated
        upstream arrives without a rebuild. The `id`s are assigned by position.

        Cost measured on tower (0.107.79, same binary, isolated instance):
        base list alone 57 MB of RSS / 2.5 MB of disk; + HaGeZi Pro 96 MB;
        + TIF medium 263 MB; + Fake 357 MB / 11 MB. RAM is the real cost, not
        disk: threat lists (very long domains) weigh ~470 bytes
        of RSS per rule, versus ~120 for an ads list. Hence a deliberately
        minimal default: each host adds what it can carry.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      host = cfg.webHost;
      port = cfg.webPort;
      mutableSettings = false; # regenerates the YAML and cleans up stray keys
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
        # Static answers: short names of the internal proxy (the service is on
        # tower, hence the mesh IP). Without it, `mesh` only resolves where a
        # /etc/hosts has been placed.
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
            # A filter without an explicit `enabled` is written `enabled: false`
            # by AdGuard, so present but inert (symptom: rules_count 0).
            enabled = if f ? enabled then f.enabled else true;
          }
        ) cfg.filters;
      };
    };

    # tailscale0's 100.64.x.y address does not necessarily exist at boot: without
    # this ordering, AdGuard loops about ten times before tailscaled
    # publishes the IP (it does eventually start, Restart=always, but noisily).
    systemd.services.adguardhome = {
      after = ["tailscaled.service"];
      wants = ["tailscaled.service"];
    };

    networking.nameservers = cfg.nameservers;
    networking.networkmanager.dns = lib.mkIf config.networking.networkmanager.enable "none";
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openWebPort [cfg.webPort];
  };
}
