# services/docs-compare/default.nix
# Comparaison de plateformes de documentation pour le rapport "Accelerators 2016-2026".
#
# Un même contenu (10 pages Markdown + 4 pages de graphiques animés autonomes)
# rendu par cinq générateurs différents, plus le hub de comparaison :
#
#   docs.marcpartensky.com        hub (mesures, tableau comparatif)      127.0.0.1:8910
#   mdbook.marcpartensky.com      mdBook                                 127.0.0.1:8911
#   mkdocs.marcpartensky.com      MkDocs Material                        127.0.0.1:8912
#   starlight.marcpartensky.com   Astro Starlight                        127.0.0.1:8913
#   docusaurus.marcpartensky.com  Docusaurus 3                           127.0.0.1:8914
#   ref.marcpartensky.com         générateur maison (référence)          127.0.0.1:8915
#   wiki.marcpartensky.com        Wiki.js 3                              127.0.0.1:8916
#
# Les builds sont produits hors Nix (chaque outil a sa toolchain : cargo pour
# mdBook, python pour MkDocs, node pour Starlight et Docusaurus, python maison
# pour la référence) puis posés dans /var/lib/docs-compare. Nix ne possède donc
# que le service et le routage : regénérer un site ne demande pas de rebuild.
#
# Contraintes qui expliquent la forme :
# - les roots sont sous /var/lib/docs-compare (0755) et non sous
#   /var/lib/hermes (0770) : l'utilisateur nginx ne peut pas traverser ce dernier.
# - chaque site a son propre port et son propre domaine, pas de préfixe d'URL :
#   Starlight et Docusaurus génèrent des chemins absolus (/assets/…), qui
#   casseraient sous un sous-répertoire sans reconfigurer leur `base`.
# - nginx écoute sur la loopback uniquement : seul newt (qui tourne sur tower)
#   joint les vhosts, rien n'est ouvert au LAN.
# - SSO Pangolin désactivé : le contenu est public (il est déjà sur droplify) et
#   une redirection de login casserait les clients qui suivent les liens.
{
  config,
  lib,
  pkgs,
  ...
}: let
  root = "/var/lib/docs-compare";

  # sous-répertoire du root -> port loopback
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

      # try_files saute vers $uri/ : nginx fabrique alors un 301 vers l'URL
      # absolue en y mettant son port d'écoute et son schéma (http), donc
      # /docs/returns partait sur http://host:8914/docs/returns/. Derrière
      # Pangolin, la seule forme correcte est une redirection RELATIVE.
      extraConfig = ''
        absolute_redirect off;
        port_in_redirect off;
      '';

      # mdBook et Starlight servent des répertoires (…/03-returns/), Docusaurus
      # et le générateur maison des fichiers .html : les trois formes passent.
      locations."/" = {
        tryFiles = "$uri $uri/ $uri.html $uri/index.html =404";
        extraConfig = ''
          # les pages portent des iframes de graphiques : pas de cache agressif,
          # un rebuild doit être visible immédiatement
          add_header Cache-Control "no-cache" always;
          add_header X-Content-Type-Options "nosniff" always;
        '';
      };
    };
  };
  # Wiki.js 3 lit /wiki/config.yml : on le génère dans le store plutôt que de le
  # poser à la main dans /var/lib, donc il est reproductible et versionné ici.
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
      # racine des builds, éditable par l'agent (hermes) sans sudo
      {
        systemd.tmpfiles.rules = [
          "d ${root} 0755 hermes hermes -"
          # Wiki.js tourne en `node` (uid 1000) dans l'image : sans ça il ne peut
          # pas écrire /wiki/data/cache (EACCES "mkdir /wiki/data/cache" au boot),
          # donc pas de cache d'icônes ni de rendu de page.
          "d /var/lib/wikijs 0755 1000 1000 -"
        ];
      }

      # Wiki.js 3 : la seule option « wiki » déployée, parce que c'est la seule
      # qui apporte OIDC, MCP et Postgres d'un coup. Ce que la comparaison doit
      # montrer : son sanitizer retire les <iframe> de graphiques, donc les
      # pages de charts y perdent l'animation que les générateurs gardent.
      # Postgres local en trust sur 127.0.0.1 (cf. services/postgres) : pas de
      # mot de passe à gérer pour une base qui ne sert qu'à cette démo.
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
          # --network=host : l'app se lie elle-même à 127.0.0.1:8916 (bindIP du
          # config.yml) et joint Postgres sur 127.0.0.1:5432 sans réseau dédié.
          extraOptions = ["--network=host" "--pull=newer"];
          # TZ explicite : les journaux Wiki.js sortent en UTC, ça les aligne sur
          # l'horloge de tower. Change aussi l'unité, donc un switch la redémarre.
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
