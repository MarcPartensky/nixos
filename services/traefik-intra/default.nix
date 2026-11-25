{ config, lib, ... }:
# INTERNAL TLS proxy of the tailnet, on tower.
#
# Two sets of names for the same backend:
#   - `<service>.intra.marcpartensky.com`: public Let's Encrypt certificate
#     (wildcard DNS-01), so valid even on a device that does not have the internal
#     root installed (borrowed phone, TV, a friend's machine).
#   - `<service>` short: certificate signed by the internal CA (step), valid
#     only where the root is installed, but tiny URL.
#
# Port 9443: 443 is the Tor relay (services/tor, ORPort 443) and 8443 is
# KasmVNC. Firewall: only trusted interfaces (tailscale0, ygg) reach
# this port, the LAN and internet do not see it.
let
  domain = "intra.marcpartensky.com";

  # Short names -> backend, single source in modules/intra-hosts.nix. Adding
  # an entry there is enough: the router, the certificate signed by the internal CA,
  # the hosts entry and the DNS rewrite are generated.
  local = import ../../modules/intra-hosts.nix;
  names = builtins.attrNames local;

  # Short PUBLIC names for the same backends: `jf.marcpartensky.com` instead
  # of `jellyfin.intra.marcpartensky.com`. The certificate is Let's Encrypt
  # (DNS-01), so accepted by any device without installing a private root:
  # it is the only way for native clients (Jellyfin Android app, TV).
  # The list lives in modules/public-hosts.nix, shared with the DNS rewrites
  # of the AdGuard instances: resolution stays internal to the tailnet, no
  # public record points to the mesh IP.
  public = import ../../modules/public-hosts.nix;

  tlsDomain = {
    certResolver = "le-dns";
    # Without `domains`, Traefik would request one certificate per hostname; here
    # the wildcard is requested ONCE, reused by all routers.
    domains = [ { main = domain; sans = [ "*.${domain}" ]; } ];
  };
in
{
  imports = [ ../../modules/nixos/intra-ca ];

  services.intraCa = {
    enable = true;
    inherit names;
  };

  services.traefik = {
    enable = true;
    # CF_DNS_API_TOKEN, rendered by sops at startup (never in the store).
    environmentFiles = [ config.sops.templates."traefik-dns.env".path ];

    staticConfigOptions = {
      entryPoints.websecure.address = ":9443";
      certificatesResolvers.le-dns.acme = {
        email = "marc.partensky@proton.me";
        storage = "/var/lib/traefik/acme.json";
        dnsChallenge = {
          provider = "cloudflare";
          resolvers = [ "1.1.1.1:53" "9.9.9.9:53" ];
        };
      };
    };

    dynamicConfigOptions = {
      http = {
        routers =
          # Short name: internal CA certificate, selected by SNI.
          (lib.mapAttrs' (name: _: lib.nameValuePair "${name}-local" {
            rule = "Host(`${name}`)";
            entryPoints = [ "websecure" ];
            service = name;
            tls = { };
          }) local)
          //
          (lib.mapAttrs' (name: _: lib.nameValuePair "${name}-intra" {
            rule = "Host(`${name}.${domain}`)";
            entryPoints = [ "websecure" ];
            service = name;
            tls = tlsDomain;
          }) local)
          //
          (lib.mapAttrs' (host: name: lib.nameValuePair "${name}-public" {
            rule = "Host(`${host}`)";
            entryPoints = [ "websecure" ];
            service = name;
            # One certificate per public name (no wildcard here: the Cloudflare
            # A record is a precise name, and the wildcard *.marcpartensky.com
            # belongs to the VPS).
            tls = {
              certResolver = "le-dns";
              domains = [ { main = host; } ];
            };
          }) public);

        services = lib.mapAttrs (name: url: {
          loadBalancer.servers = [ { url = url; } ];
        }) local;
      };

      # Certificates are declared at the ROOT of the dynamic file, not under
      # `http`: otherwise Traefik rejects the config ("field not found, node: tls").
      # Leaf files written by intra-ca-issue (systemd, before traefik).
      tls.certificates = map (name: {
        certFile = "/var/lib/traefik-certs/${name}.crt";
        keyFile = "/var/lib/traefik-certs/${name}.key";
      }) names;
    };
  };

  # Tor holds 0.0.0.0:443 on tower (ORPort). A REDIRECT in PREROUTING limited
  # to the mesh IP alone sends the tailnet's 443 to entrypoint 9443:
  # `https://mesh` works without a port, and the Tor relay is not touched. The
  # packets concerned arrive via tailscale0, so the LAN and internet are
  # not affected.
  networking.firewall.extraCommands = ''
    iptables -t nat -C PREROUTING -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443 2>/dev/null || \
    iptables -t nat -A PREROUTING -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443
    # Traffic emitted BY tower to its own mesh IP goes out via OUTPUT: it does not
    # pass through PREROUTING and thus hit the Tor relay (0.0.0.0:443).
    # Without this rule, `https://jellyfin` fails in tower's browser
    # while it works from the other nodes.
    iptables -t nat -C OUTPUT -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443 2>/dev/null || \
    iptables -t nat -A OUTPUT -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443
  '';

  # Cloudflare token (Zone:DNS:Edit on marcpartensky.com), encrypted for tower
  # only. Deliberately ABSENT from anywhere.yml, which tower cannot
  # decrypt.
  sops.secrets."traefik/cloudflare_dns" = {
    sopsFile = ../../secrets/traefik.yml;
    key = "cloudflare_dns_token";
    mode = "0400";
  };

  sops.templates."traefik-dns.env" = {
    mode = "0400";
    content = ''CF_DNS_API_TOKEN=${config.sops.placeholder."traefik/cloudflare_dns"}'';
  };
}
