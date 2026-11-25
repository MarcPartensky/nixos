# services/docs-compare/default.nix
# Comparison of documentation platforms for the "Accelerators 2016-2026" report.
#
# The same content (10 Markdown pages + 4 self-contained animated chart pages)
# rendered by five different generators, plus the comparison hub:
#
#   docs.marcpartensky.com        hub (measurements, comparison table)      127.0.0.1:8910
#   mdbook.marcpartensky.com      mdBook                                 127.0.0.1:8911
#   mkdocs.marcpartensky.com      MkDocs Material                        127.0.0.1:8912
#   starlight.marcpartensky.com   Astro Starlight                        127.0.0.1:8913
#   docusaurus.marcpartensky.com  Docusaurus 3                           127.0.0.1:8914
#   ref.marcpartensky.com         home-grown generator (reference)       127.0.0.1:8915
#   wiki.marcpartensky.com        Wiki.js 3                              127.0.0.1:8916
#
# The builds are produced outside Nix (each tool has its own toolchain: cargo for
# mdBook, python for MkDocs, node for Starlight and Docusaurus, home-grown python
# for the reference) then placed in /var/lib/docs-compare. Nix therefore only owns
# the service and the routing: regenerating a site does not require a rebuild.
#
# Constraints that explain the shape:
# - the roots are under /var/lib/docs-compare (0755) and not under
#   /var/lib/hermes (0770): the nginx user cannot traverse the latter.
# - each site has its own port and its own domain, no URL prefix:
#   Starlight and Docusaurus generate absolute paths (/assets/...), which
#   would break under a sub-directory without reconfiguring their `base`.
# - nginx listens on loopback only: only newt (which runs on tower)
#   reaches the vhosts, nothing is open to the LAN.
# - Pangolin SSO disabled: the content is public (it is already on droplify) and
#   a login redirect would break the clients that follow the links.
{
  config,
  lib,
  pkgs,
  ...
}: let
  root = "/var/lib/docs-compare";

  # sub-directory of the root -> loopback port
  sites = {
    hub = 8910;
    mdbook = 8911;
    mkdocs = 8912;
    starlight = 8913;
    docusaurus = 8914;
    ref = 8915;
  };

  staticVhost = name: port: {
    services.nginx.virtualHosts."docs-compare-${name}" = {
      listen = [
        {
          addr = "127.0.0.1";
          inherit port;
        }
      ];
      root = "${root}/${name}";

      # try_files jumps to $uri/: nginx then builds a 301 to the absolute
      # URL putting its listening port and scheme (http) in it, so
      # /docs/returns went to http://host:8914/docs/returns/. Behind
      # Pangolin, the only correct form is a RELATIVE redirect.
      extraConfig = ''
        absolute_redirect off;
        port_in_redirect off;
      '';

      # mdBook and Starlight serve directories (.../03-returns/), Docusaurus
      # and the home-grown generator serve .html files: all three forms pass.
      locations."/" = {
        tryFiles = "$uri $uri/ $uri.html $uri/index.html =404";
        extraConfig = ''
          # the pages carry chart iframes: no aggressive cache,
          # a rebuild must be visible immediately
          add_header Cache-Control "no-cache" always;
          add_header X-Content-Type-Options "nosniff" always;
        '';
      };
    };
  };
  # Wiki.js 3 reads /wiki/config.yml: we generate it in the store rather than
  # placing it by hand in /var/lib, so it is reproducible and versioned here.
  wikiConfig = pkgs.writeText "wikijs-cmp-config.yml" ''
    port: 8916
    bindIP: 127.0.0.1
    db:
      host: '127.0.0.1'
      port: 5432
      user: 'wikijs_cmp'
      pass: 'wikijs_cmp'
      db: 'wikijs_cmp'
      schema: public
      ssl: false
    logLevel: info
    logFormat: default
    dataPath: /wiki/data
    scheduler:
      workers: 2
  '';

in {
  config = lib.mkMerge (
    [
      # root of the builds, editable by the agent (hermes) without sudo
      {
        systemd.tmpfiles.rules = [
          "d ${root} 0755 hermes hermes -"
          # Wiki.js runs as `node` (uid 1000) in the image: without this it cannot
          # write /wiki/data/cache (EACCES "mkdir /wiki/data/cache" at boot),
          # hence no icon cache nor page rendering.
          "d /var/lib/wikijs 0755 1000 1000 -"
        ];
      }

      # Wiki.js 3: the only "wiki" option deployed, because it is the only one
      # that brings OIDC, MCP and Postgres at once. What the comparison must
      # show: its sanitizer strips the chart <iframe>s, so the
      # chart pages there lose the animation that the generators keep.
      # Local Postgres in trust on 127.0.0.1 (cf. services/postgres): no
      # password to manage for a database that only serves this demo.
      {
        services.postgresql.ensureDatabases = ["wikijs_cmp"];
        services.postgresql.ensureUsers = [
          {
            name = "wikijs_cmp";
            ensureDBOwnership = true;
          }
        ];

        virtualisation.oci-containers.backend = lib.mkDefault "podman";
        virtualisation.oci-containers.containers.wikijs-cmp = {
          image = "ghcr.io/requarks/wiki:3";
          autoStart = true;
          # --network=host: the app binds itself to 127.0.0.1:8916 (bindIP of the
          # config.yml) and reaches Postgres on 127.0.0.1:5432 without a dedicated network.
          extraOptions = ["--network=host" "--pull=newer"];
          # Explicit TZ: the Wiki.js logs come out in UTC, this aligns them on
          # tower's clock. Also changes the unit, so a switch restarts it.
          environment = {
            TZ = "America/New_York";
          };
          volumes = [
            "${wikiConfig}:/wiki/config.yml:ro"
            "/var/lib/wikijs:/wiki/data"
          ];
        };
      }
    ]
    ++ map (n: staticVhost n sites.${n}) (builtins.attrNames sites)
  );
}
