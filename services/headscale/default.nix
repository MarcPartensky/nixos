{ pkgs, config, ... }:
let
  # Host names shared with the AdGuard instances (modules/mesh-hosts.nix).
  meshHosts = import ../../modules/mesh-hosts.nix;
in
{
  # marc's headscale mesh controller (HARDENED version).
  #
  # Runs on the `anywhere` VPS, the only host with a stable public IP, and provides:
  #   - coordination of the tailscale nodes (tower, deck, anywhere, laptop...);
  #   - an embedded DERP: encrypted fallback relay when hole punching
  #     fails. Traffic flows there in WireGuard, the relay decrypts nothing.
  #
  # Hardening (compared to public tailscale.com):
  #   - derp.urls = [] : the Tailscale Inc DERP fleet is removed from the map
  #     announced to clients; the only relay is this VPS's, which is
  #     part of the network. No external machine sees the nodes' IPs.
  #   - logtail.enabled = false : no client log is sent to Tailscale Inc.
  #
  # On the clients: services/tailscale/default.nix, to import on each NixOS
  # machine of the flake.
  #
  # Exposure: headscale.marcpartensky.com -> local Traefik (Pangolin) ->
  # 127.0.0.1:8090 over HTTP; the route is in services/traefik/dynamic.toml.
  # The embedded DERP goes through the SAME HTTPS endpoint (/derp), hence through
  # Traefik; only STUN (UDP 3478) is exposed directly, since a reverse proxy
  # does not carry UDP.
  #
  # Bootstrap / rotation: see at the bottom of the file.
  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = 8090;
    settings = {
      # Public URL that clients use to join the tailnet.
      server_url = "https://headscale.marcpartensky.com";
      # Traefik runs locally on this VPS: honor its X-Forwarded-*.
      trusted_proxies = [ "127.0.0.1/32" ];

      derp = {
        # No external DERP map: only the embedded DERP below.
        urls = [ ];
        paths = [ ];
        auto_update_enabled = false;
        server = {
          enabled = true;
          region_id = 900; # outside the range of official regions (1-30)
          region_code = "vps";
          region_name = "VPS RackNerd";
          # STUN: helps hole punching, in direct UDP on the public IP.
          stun_listen_addr = "0.0.0.0:3478";
          # The embedded DERP region is added to the map automatically,
          # announced on server_url (port 443, via Traefik).
          automatically_add_embedded_derp_region = true;
          # Only the tailnet nodes can use this relay.
          verify_clients = true;
          # private_key_path : module default
          # (/var/lib/headscale/derp_server_private.key, generated on first boot)
        };
      };

      # ACL from a HuJSON file (mode "file").
      policy = {
        mode = "file";
        path = ./policy.hujson;
      };

      # No client log to Tailscale Inc (0.28 default, made explicit here).
      logtail.enabled = false;

      dns = {
        magic_dns = true;
        base_domain = "ts.marcpartensky.com";
        # Internal-only host names, answered by MagicDNS on every node. They
        # live in the tailnet DNS, not in the public Cloudflare zone: the
        # daemon serves them from this record table and never forwards them
        # upstream. The same list feeds the AdGuard rewrites, so a client that
        # bypasses MagicDNS (macOS with a manual resolver) gets the same answer.
        extra_records = map (h: {
          name = "${h.name}.marcpartensky.com";
          type = "A";
          value = h.ip;
        }) meshHosts;

        # AdGuard is the resolver for the WHOLE tailnet: filtering therefore
        # applies to devices away from home (phone, laptop, Mac), with no
        # per-device conf, since the controller pushes these IPs.
        # Two instances, in this order:
        #  - 100.64.0.1 : the VPS, always on and colocated with the internet
        #    exit node, hence the only one that guarantees filtering on the go;
        #  - 100.64.0.3 : tower, one hop from the home LAN;
        #  - 1.1.1.1 : raw safety net if both AdGuard are dead (a blocked
        #    domain is answered 0.0.0.0, so the fallback leaks nothing worse
        #    than a public domain).
        nameservers.global = [ "100.64.0.1" "100.64.0.3" "1.1.1.1" ];
        # Without this flag headscale pushes NOTHING (`tailscale dns status` shows
        # "no resolvers configured"), even with nameservers.global filled.
        override_local_dns = true;
      };
    };
  };

  environment.systemPackages = [ config.services.headscale.package ];

  # STUN of the embedded DERP: direct UDP, Traefik does not carry UDP.
  networking.firewall.allowedUDPPorts = [ 3478 ];
}

# ================================ BOOTSTRAP ================================
#
# Already in place (23/10/2026):
#   - headscale user `marc` (id 1);
#   - reusable pre-authentication key (expiration 10 years, id 2),
#     encrypted in secrets/headscale.yml (key `preauth_key`), consumed by
#     services/tailscale on each machine.
#
# Rotation / new key (after revocation for example):
#   sudo headscale users list                          # find marc's id
#   sudo headscale preauthkeys create -u <id> --reusable --expiration 0
#   # replace preauth_key in secrets/headscale.yml (sops), redeploy.
#
# Revoking a node: sudo headscale nodes delete -i <id> (or nodes expire
# to force a re-authentication).
#
# Nodes do not expire (Expiration 0001-01-01 in `nodes list`); to
# set one if desired:
#   sudo headscale nodes expire -i <id> -e 2036-01-01T00:00:00Z
