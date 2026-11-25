{ config, lib, ... }:
# Proxy TLS INTERNE du tailnet, sur tower.
#
# Deux jeux de noms pour le meme backend :
#   - `<service>.intra.marcpartensky.com` : certificat public Let's Encrypt
#     (wildcard DNS-01), donc valide meme sur un appareil qui n'a pas la racine
#     interne installee (telephone pretе, TV, machine d'un ami).
#   - `<service>` tout court : certificat signe par la CA interne (step), valide
#     uniquement la ou la racine est installee, mais URL minuscule.
#
# Port 9443 : 443 est le relais Tor (services/tor, ORPort 443) et 8443 est
# KasmVNC. Firewall : seules les interfaces trusted (tailscale0, ygg) joignent
# ce port, le LAN et internet ne le voient pas.
let
  domain = "intra.marcpartensky.com";

  # Noms courts -> backend, source unique dans modules/intra-hosts.nix. Ajouter
  # une entree la-bas suffit : le routeur, le certificat signe par la CA interne,
  # l'entree hosts et le rewrite DNS sont generes.
  local = import ../../modules/intra-hosts.nix;
  names = builtins.attrNames local;

  # Noms PUBLICS courts pour les memes backends : `jf.marcpartensky.com` au lieu
  # de `jellyfin.intra.marcpartensky.com`. Le certificat est Let's Encrypt
  # (DNS-01), donc accepte par tout appareil sans installer de racine privee :
  # c'est la seule voie pour les clients natifs (app Jellyfin Android, TV).
  # La liste vit dans modules/public-hosts.nix, partagee avec les rewrites DNS
  # des instances AdGuard : la resolution reste interne au tailnet, aucun
  # enregistrement public ne pointe vers l'IP mesh.
  public = import ../../modules/public-hosts.nix;

  tlsDomain = {
    certResolver = "le-dns";
    # Sans `domains`, Traefik demanderait un certificat par nom d'hote ; ici on
    # demande UNE fois le wildcard, reutilise par tous les routeurs.
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
    # CF_DNS_API_TOKEN, rendu par sops au demarrage (jamais dans le store).
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
          # Nom court : certificat de la CA interne, selectionne par SNI.
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
            # Un certificat par nom public (pas de wildcard ici : le A
            # Cloudflare est un nom precis, et le wildcard *.marcpartensky.com
            # appartient au VPS).
            tls = {
              certResolver = "le-dns";
              domains = [ { main = host; } ];
            };
          }) public);

        services = lib.mapAttrs (name: url: {
          loadBalancer.servers = [ { url = url; } ];
        }) local;
      };

      # Les certificats se declarent a la RACINE du fichier dynamique, pas sous
      # `http` : sinon Traefik refuse la config (« field not found, node: tls »).
      # Feuilles ecrites par intra-ca-issue (systemd, avant traefik).
      tls.certificates = map (name: {
        certFile = "/var/lib/traefik-certs/${name}.crt";
        keyFile = "/var/lib/traefik-certs/${name}.key";
      }) names;
    };
  };

  # Tor tient 0.0.0.0:443 sur tower (ORPort). Un REDIRECT en PREROUTING limite
  # a la seule IP du mesh renvoie le 443 du tailnet vers l'entrypoint 9443 :
  # `https://mesh` marche sans port, et le relais Tor n'est pas touche. Les
  # paquets concernes arrivent par tailscale0, donc le LAN et internet ne sont
  # pas affectes.
  networking.firewall.extraCommands = ''
    iptables -t nat -C PREROUTING -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443 2>/dev/null || \
    iptables -t nat -A PREROUTING -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443
    # Le trafic emis PAR tower vers sa propre IP mesh sort en OUTPUT : il ne
    # passe pas par PREROUTING et frappait donc le relais Tor (0.0.0.0:443).
    # Sans cette regle, `https://jellyfin` echoue dans le navigateur de tower
    # alors qu'il marche depuis les autres noeuds.
    iptables -t nat -C OUTPUT -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443 2>/dev/null || \
    iptables -t nat -A OUTPUT -d 100.64.0.3 -p tcp --dport 443 -j REDIRECT --to-ports 9443
  '';

  # Token Cloudflare (Zone:DNS:Edit sur marcpartensky.com), chiffre pour tower
  # uniquement. Volontairement ABSENT de anywhere.yml, que tower ne peut pas
  # dechiffrer.
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
