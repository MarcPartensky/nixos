{ config, pkgs, ... }:

{
  ## ===== AdGuard Home =====
  services.adguardhome = {
    enable = true;

    # écoute uniquement en local (safe)
    host = "127.0.0.1";
    port = 3000;

    # DNS local
    settings = {
      host = "127.0.0.1";
      port = 53;

      # upstream DNS (rapide et clean)
      upstream_dns = [
        # "https://1.1.1.1/dns-query"
        # "https://9.9.9.9/dns-query"
        "127.0.0.1:53"
      ];

      bootstrap_dns = [
        "1.1.1.1"
        "9.9.9.9"
      ];

      ## ===== PERF =====
      cache_size = 4194304; # 4 MB
      ratelimit = 0;        # disable rate limit
      blocked_response_ttl = 60;

      ## ===== LOGS (OFF) =====
      querylog_enabled = false;
      statistics_enabled = true;
      statistics_interval = 24;

      ## ===== FILTRAGE =====
      filtering_enabled = true;

      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
      ];

      ## ===== SAFE =====
      protection_enabled = true;
      safe_search = {
        enabled = false;
      };
    };
  };

  ## ===== DNS SYSTEME =====
  networking.nameservers = [ "127.0.0.1" ];

  ## évite que resolvconf écrase le DNS
  networking.networkmanager.dns = "none";

  ## firewall (DNS local uniquement)
  networking.firewall.allowedTCPPorts = [ 3000 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}

