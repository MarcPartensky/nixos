# Single source of truth for the tailnet host names.
#
# Consumed twice:
#   - headscale `dns.extra_records`, answered by MagicDNS inside each client;
#   - AdGuard `filtering.rewrites`, answered for clients that query AdGuard
#     directly (macOS with a manual resolver, containers, anything that does
#     not go through the tailscaled stub).
#
# Keep both in sync by editing only this file: the two resolvers must give the
# same answer, otherwise the name depends on which one is asked.
#
# `vps` is the mesh address of the always-on node; its public address stays in
# the Cloudflare zone and is not part of the tailnet DNS.
[
  {
    name = "tower";
    ip = "100.64.0.3";
  }
  {
    name = "deck";
    ip = "100.64.0.2";
  }
  {
    name = "laptop";
    ip = "100.64.0.4";
  }
  {
    name = "mac";
    ip = "100.64.0.5";
  }
  {
    name = "phone";
    ip = "100.64.0.10";
  }
  {
    name = "vps";
    ip = "100.64.0.1";
  }
]
