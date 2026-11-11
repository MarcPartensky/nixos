# services/shlink/default.nix
# Shlink (github.com/shlinkio/shlink) : raccourcisseur d'URL auto-hébergé,
# serveur REST v3 complet (short URLs, visites, tags, domaines, redirect rules).
# Exposé sur s.marcpartensky.com.
#
# Choix d'architecture (voir aussi services/shlink-mcp) :
#   - moteur dans un conteneur OCI (pas de paquet nixpkgs : jamais packagé),
#     même pattern que reactive-resume / open-notebook ;
#   - --network=host : l'app doit joindre Postgres en 127.0.0.1:5432 avec la
#     convention "trust/md5 loopback" du reste de tower ; le port applicatif
#     (8097) reste fermé au firewall, seule la ressource Pangolin l'expose ;
#   - Postgres dédié (rôle + base `shlink`), mot de passe sops aligné par un
#     oneshot, comme reactive-resume ;
#   - SSO Pangolin DÉSACTIVÉ volontairement : les liens courts doivent
#     résoudre pour n'importe qui (un 302 vers Zitadel casserait tout lien
#     partagé). La protection de l'API est la clé d'API Shlink, pas le proxy ;
#     le serveur Shlink n'a de toute façon aucune UI web.
#
# Non couvert ici : la géolocalisation des visites, qui exige une clé de
# licence GeoLite2 (compte MaxMind, non FOSS côté base). Ajouter alors
# GEOLITE_LICENSE_KEY dans le template d'env ci-dessous ; sans elle Shlink
# démarre normalement, seules les stats pays/ville restent vides.
{
  config,
  lib,
  pkgs,
  ...
}: let
  port = 8097;
  domain = "s.marcpartensky.com";
in {
  # ── Secrets ────────────────────────────────────────────────────────────
  # NOMS PLATS volontairement : un nom avec slash (`shlink/db_password`) fait
  # créer un sous-dossier /run/secrets/<n>/ en drwxr-x--x root:keys, que le
  # user `postgres` ne peut pas traverser (ni lire le fichier) : le oneshot
  # ci-dessous sortait en « cat: Permission denied », le rôle restait sans mot
  # de passe et le conteneur mourait sur « Error updating database ».
  sops.secrets.shlink_db_password = {
    key = "shlink_db_password";
    sopsFile = ../../secrets/shlink.yml;
    # Lu par shlink-db-password.service (User=postgres).
    owner = "postgres";
  };

  # Clé d'API Shlink : sert à la fois de INITIAL_API_KEY au premier démarrage
  # et de credential au MCP (services/shlink-mcp, qui tourne en user hermes).
  sops.secrets.shlink_api_key = {
    key = "shlink_api_key";
    sopsFile = ../../secrets/shlink.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  # Env du conteneur : rendu déchiffré à l'activation (jamais dans le store).
  sops.templates."shlink.env" = {
    mode = "0400";
    content = ''
      TZ=America/New_York
      DEFAULT_DOMAIN=${domain}
      IS_HTTPS_ENABLED=true
      PORT=${toString port}
      DB_DRIVER=postgres
      DB_HOST=127.0.0.1
      DB_PORT=5432
      DB_NAME=shlink
      DB_USER=shlink
      DB_PASSWORD=${config.sops.placeholder.shlink_db_password}
      INITIAL_API_KEY=${config.sops.placeholder.shlink_api_key}
    '';
  };

  # ── Base Postgres dédiée ───────────────────────────────────────────────
  services.postgresql = {
    ensureDatabases = ["shlink"];
    ensureUsers = [
      {
        name = "shlink";
        ensureDBOwnership = true;
      }
    ];
    # mkOverride 10 : concatène au lieu de remplacer les règles des autres
    # modules (postgres, reactive-resume, vaultwarden, gitea...).
    authentication = lib.mkOverride 10 ''
      host    shlink  shlink  127.0.0.1/32  md5
    '';
  };

  # Aligne le mot de passe du rôle sur le secret sops (ensureUsers n'en pose
  # pas). Tourne avant le conteneur, rejouable à chaque switch.
  #
  # `postgresql-setup.service` est requis EXPLICITEMENT : il crée le rôle et la
  # base (ensureUsers/ensureDatabases) mais tourne comme une unité à part,
  # redémarrée par le switch. Se contenter de `after = postgresql.service` ne
  # suffit pas quand postgres est déjà actif : cette dépendance est un job
  # no-op, donc le oneshot pouvait partir avant la création du rôle et sortir
  # en « ERROR: role "shlink" does not exist » (vécu au premier switch).
  systemd.services.shlink-db-password = {
    description = "Aligne le mot de passe du rôle postgres shlink sur le secret sops";
    wantedBy = ["multi-user.target"];
    before = ["podman-shlink.service"];
    requiredBy = ["podman-shlink.service"];
    after = ["postgresql.service" "postgresql-setup.service"];
    requires = ["postgresql.service" "postgresql-setup.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -v pw="$(cat ${config.sops.secrets.shlink_db_password.path})" <<'SQL'
      ALTER ROLE "shlink" WITH PASSWORD :'pw';
      SQL
    '';
  };

  # ── Données du conteneur ───────────────────────────────────────────────
  # 0777 : l'uid interne de l'image shlinkio/shlink n'est pas garanti
  # (l'image tourne en non-root depuis la v4) et le volume doit rester
  # inscriptible quel que soit cet uid. Rien de sensible dedans (pas de SQLite
  # puisque Postgres, seulement les downloads GeoLite éventuels et les locks).
  systemd.tmpfiles.rules = [
    "d /var/lib/shlink 0777 root root -"
    "d /var/lib/shlink/data 0777 root root -"
  ];

  # ── Conteneur ──────────────────────────────────────────────────────────
  virtualisation.oci-containers.containers.shlink = {
    image = "docker.io/shlinkio/shlink:stable";
    autoStart = true;
    volumes = ["/var/lib/shlink/data:/etc/shlink/data"];
    environmentFiles = [config.sops.templates."shlink.env".path];
    # Pas de --health-cmd : l'image ne garantit ni curl ni wget, et un
    # healthcheck en échec permanent rend le conteneur "unhealthy" sans
    # informer personne. La santé réelle est vérifiée par Pangolin sur
    # /rest/health (voir la ressource plus bas), qui est l'endpoint que Shlink
    # documente pour ça.
    extraOptions = [
      "--network=host"
      "--pull=newer"
    ];
  };

  systemd.services."podman-shlink" = {
    after = [
      "network-online.target"
      "postgresql.service"
      "shlink-db-password.service"
    ];
    wants = ["network-online.target"];
    requires = ["shlink-db-password.service"];
  };

  # ── Exposition publique (Pangolin/newt) ────────────────────────────────
  # Schéma `proxy-resources` + `protocol` (celui qui marche sur ce
  # contrôleur). auth.sso-enabled = false : indispensable pour que les
  # redirections /<slug> soient publiques. Healthcheck sur /rest/health, qui
  # répond 200 sans clé d'API (endpoint dédié santé).
  services.newt.blueprint.proxy-resources.shlink = {
    name = "shlink";
    protocol = "http";
    full-domain = domain;
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
          path = "/rest/health";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # ── Sauvegarde ─────────────────────────────────────────────────────────
  # Le dump Postgres quotidien de tower couvrait nextcloud uniquement : les
  # liens vivent en base, donc sans ça un disque perdu = tous les liens perdus.
  services.postgresqlBackup.databases = lib.mkAfter ["shlink"];

  # ── Garde-fous ─────────────────────────────────────────────────────────
  assertions = [
    {
      # --network=host expose 8097 sur toutes les interfaces : seul le firewall
      # empêche un accès LAN direct (l'API n'a qu'une clé, pas d'IP allowlist).
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "shlink : le port ${toString port} ne doit pas être ouvert au firewall (exposition uniquement via Pangolin/newt).";
    }
  ];
}
