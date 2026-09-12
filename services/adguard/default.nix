{
  config,
  pkgs,
  ...
}: {
  services.adguardhome = {
    enable = true;
    host = "127.0.0.1";
    port = 3000;
    mutableSettings = false; # régénère le YAML et nettoie les clés parasites
    settings = {
      dns = {
        bind_hosts = ["127.0.0.1"];
        port = 53;
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.quad9.net/dns-query"
        ];
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

  networking.nameservers = ["1.1.1.1"]; # bascule sur 127.0.0.1 après test
  networking.networkmanager.dns = "none";
  networking.firewall.allowedTCPPorts = [3000];
}
