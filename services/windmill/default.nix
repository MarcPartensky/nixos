{ config, lib, pkgs, ... }:
# Windmill : orchestrateur de taches (serveur + workers) pour la flotte.
#
# Architecture Windmill : le serveur sert l'UI/API et ecrit dans Postgres ; les
# workers ne parlent PAS au serveur, ils se connectent a la meme base et
# prennent des jobs dans la file. Consequence pour la flotte : chaque worker
# n'a besoin que d'un acces Postgres (tailnet) et de rien d'autre. Un worker qui
# tombe (veille, wifi, reboot) reprend au retour, sans etat local a reconcilier.
#
# Sur tower : role = "server" (base + serveur + un worker local).
# Sur deck / anywhere : role = "worker", dbHost = "100.64.0.3" (tower, tailnet).
#
# Le conteneur est l'image officielle epinglee (amd64 + arm64) : pas de build
# Rust local, et tous les runtimes de script (python, node, bun, go) sont dans
# l'image, pas sur l'hote.
let
  cfg = config.services.windmillFleet;
  image = "ghcr.io/windmill-labs/windmill:${cfg.version}";
  stateDir = "/var/lib/windmill";
  # Le serveur tape Postgres en local : l'authentification locale de
  # services/postgres est `trust` sur 127.0.0.1, donc pas de mot de passe.
  # Les workers distants passent par le tailnet, en scram, avec le secret.
  dbUrl = host: pass:
    "postgresql://windmill" + (if pass == "" then "" else ":${pass}") + "@${host}:5432/windmill";
in
{
  options.services.windmillFleet = {
    enable = lib.mkEnableOption "Windmill (orchestrateur de taches de la flotte)";

    role = lib.mkOption {
      type = lib.types.enum [ "server" "worker" ];
      default = "worker";
      description = "server : base + UI/API. worker : prend des jobs et les execute.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "1.864.1";
      description = "Tag de l'image ghcr.io/windmill-labs/windmill (epingle, jamais `main`).";
    };

    workerGroup = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Groupe de workers : un script peut exiger `<groupe>` pour aller sur cette machine.";
    };

    workers = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Jobs simultanes sur ce noeud (NUM_WORKERS).";
    };

    dbHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Hote Postgres. `127.0.0.1` pour le serveur, `100.64.0.3` (tower sur le tailnet) pour un worker distant.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8010";
      description = "URL publique du serveur (liens et CORS).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8010;
      description = "Port d'ecoute du serveur (8000 est pris par audiobookshelf sur tower).";
    };

    expose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Declarer la ressource Pangolin (SSO) windmill.marcpartensky.com vers 127.0.0.1:8010.";
    };

    noAuth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        NO_AUTH=true : Windmill ne demande plus de login et sert tout en
        superadmin. A n'activer QUE derriere un proxy qui authentifie deja
        (Pangolin SSO). L'OIDC applicatif de Windmill est une fonction
        Enterprise : en CE, build_oauth_clients() et list_logins() sont des
        stubs ("Implementation is not open source"), donc brancher Zitadel
        DANS Windmill n'est pas possible sans licence.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.backend = "podman";
    virtualisation.podman.enable = true;

    sops.secrets."windmill_pg_password" = {
      sopsFile = ../../secrets/windmill.yml;
      owner = "root";
      mode = "0400";
    };

    sops.templates."windmill.env" = {
      owner = "root";
      mode = "0400";
      content = ''
        DATABASE_URL=${dbUrl cfg.dbHost (builtins.toString config.sops.placeholder."windmill_pg_password")}
      '';
    };

    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

    virtualisation.oci-containers.containers."windmill-${cfg.role}" = {
      inherit image;
      environmentFiles = [ config.sops.templates."windmill.env".path ];
      environment =
        if cfg.role == "server" then {
          MODE = "server";
          BASE_URL = cfg.baseUrl;
          PORT = toString cfg.port;
        } // lib.optionalAttrs cfg.noAuth {
          NO_AUTH = "true";
        } else {
          MODE = "worker";
          WORKER_GROUP = cfg.workerGroup;
          NUM_WORKERS = toString cfg.workers;
          BASE_INTERNAL_URL = cfg.baseUrl;
        };
      volumes = [ "${stateDir}:/tmp/windmill" ];
      # `host` pour que le serveur (8000) et les workers (Postgres) joignent la
      # loopback de la machine sans NAT podman supplementaire.
      extraOptions = [ "--network=host" ];
      # Le conteneur tourne en root : l'image ecrit dans /tmp/windmill (monte).
    };

    # Base + role + acces tailnet : uniquement sur le serveur.
    systemd.services.windmillFleet-db = lib.mkIf (cfg.role == "server") {
      description = "Windmill : roles Postgres + mot de passe (idempotent)";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" "postgresql-setup.service" ];
      requires = [ "postgresql.service" ];
      path = [ pkgs.postgresql ];
      script = ''
        set -eu
        for i in $(seq 1 60); do
          pg_isready -h 127.0.0.1 -q && break
          sleep 1
        done
        # TCP loopback : l'authentification locale y est `trust` (la socket
        # unix, elle, est en `peer` : un `psql -U postgres` par socket est
        # refuse, vecu au premier switch).
        PSQL="psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -q"
        # Windmill exige deux roles de groupe (NOLOGIN) que son docker
        # entrypoint cree normalement : sans eux la premiere migration echoue
        # sur `role "windmill_admin" does not exist`.
        for role in windmill_admin windmill_user; do
          if [ "$($PSQL -d postgres -tAc "select 1 from pg_roles where rolname='$role'")" != "1" ]; then
            $PSQL -d postgres -c "create role $role nologin"
          fi
          $PSQL -d postgres -c "grant $role to windmill"
        done
        $PSQL -d windmill -c "GRANT ALL ON SCHEMA public TO windmill_admin" \
                           -c "GRANT ALL ON SCHEMA public TO windmill_user"
        # psql -f via un fichier temporaire : `-c` n'interprete PAS les
        # variables psql (`:'pw'` part tel quel et casse en erreur de syntaxe,
        # vecu), et le mot de passe ne doit pas apparaitre dans la ligne de
        # commande. Le doublement des quotes simples passe par une variable
        # (une paire de quotes litterale serait l'echappement de la chaine Nix).
        umask 077
        tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
        q="'"
        pw="$(cat ${config.sops.secrets."windmill_pg_password".path})"
        # Le prefixe quote-quote devant l'accolade est l'echappement Nix qui
        # rend l'interpolation litterale (c'est du bash, pas du Nix).
        printf "alter role windmill with login password '%s';\n" "''${pw//$q/$q$q}" > "$tmp"
        $PSQL -d postgres -f "$tmp"
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
    };

    # Le serveur applique ses migrations au demarrage : les roles doivent
    # exister avant, sinon il tombe en boucle (start-limit-hit).
    systemd.services.podman-windmill-server = lib.mkIf (cfg.role == "server") {
      after = [ "windmillFleet-db.service" ];
      wants = [ "windmillFleet-db.service" ];
    };

    services.postgresql.ensureDatabases = lib.mkIf (cfg.role == "server") [ "windmill" ];
    services.postgresql.ensureUsers = lib.mkIf (cfg.role == "server") [
      {
        name = "windmill";
        ensureDBOwnership = true;
        ensureClauses = {
          login = true;
        };
      }
    ];

    # Les workers Windmill ne parlent pas au serveur : ils lisent la file dans
    # Postgres. D'ou l'ecoute hors loopback, fermee trois fois : firewall
    # (5432 sur tailscale0 seulement), pg_hba (role windmill / base windmill /
    # scram, depuis 100.64.0.0/10), et le tailnet WireGuard lui-meme.
    services.postgresql.settings.listen_addresses = lib.mkIf (cfg.role == "server") "*";

    # 5432 joignable par les noeuds du tailnet uniquement (WireGuard), et le
    # seul role autorise a distance est `windmill` sur la base `windmill`.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts =
      lib.mkIf (cfg.role == "server") [ 5432 ];

    services.newt.blueprint.proxy-resources.windmill = lib.mkIf (cfg.role == "server" && cfg.expose) {
      name = "windmill";
      protocol = "http";
      full-domain = "windmill.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = cfg.port;
          method = "http";
        }
      ];
    };
  };
}
