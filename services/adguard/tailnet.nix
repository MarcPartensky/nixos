# DNS policy shared by the AdGuard instances that serve the tailnet.
#
# Both instances are advertised to every node by headscale, and tailscaled
# queries them in parallel, keeping the first answer. They must therefore
# expose the SAME blocklists and the SAME static rewrites: otherwise whether a
# domain is blocked depends on which instance happens to answer first.
#
# Only per-host settings (bindHosts) stay in the host profiles.
{ lib, ... }:
let
  # Host names shared with headscale (modules/mesh-hosts.nix).
  meshHosts = import ../../modules/mesh-hosts.nix;
  # Mesh address of the internal TLS proxy (tower).
  intraProxy = "100.64.0.3";
  rewrite = domain: ip: {
    inherit domain;
    answer = ip;
    enabled = true;
  };
in
{
  services.dnsFilter.filters = [
    {
      name = "AdGuard DNS filter";
      url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt";
    }
    {
      name = "HaGeZi Pro";
      url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt";
    }
    {
      name = "HaGeZi TIF medium";
      url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.medium.txt";
    }
    {
      name = "HaGeZi Fake";
      url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt";
    }
  ];

  # AdGuard answers the tailnet names itself, in addition to filtering. MagicDNS
  # normally answers them first (the query never reaches AdGuard), but a client
  # with a manual resolver (macOS networksetup) or any process that bypasses the
  # tailscaled stub asks AdGuard directly and must get the same answer.
  #
  # `enabled = true` is NOT optional: without it AdGuard writes the rewrite but
  # keeps it disabled, and the name only resolves where a /etc/hosts entry
  # exists. With two resolvers racing, that is worse than no rewrite at all:
  # the instance without the name returns NXDOMAIN and can win the race.
  services.dnsFilter.extraRewrites =
    # Short names of the internal TLS proxy (services/traefik-intra on tower).
    # Read from the same list that declares the routers, so a new name can
    # never resolve on one resolver and not on the other.
    lib.mapAttrsToList (name: _: rewrite name intraProxy)
      (import ../../modules/intra-hosts.nix)
    # Public names of the same proxy: they carry a Let's Encrypt certificate
    # (accepted everywhere) but are still resolved only here, inside the
    # tailnet. No public DNS record points to the mesh address.
    ++ lib.mapAttrsToList (host: _: rewrite host intraProxy)
      (import ../../modules/public-hosts.nix)
    ++ lib.concatMap (h: [
      (rewrite h.name h.ip)
      (rewrite "${h.name}.marcpartensky.com" h.ip)
    ]) meshHosts;
}
