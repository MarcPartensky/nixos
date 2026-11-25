{ config, lib, pkgs, ... }:
# Windmill: task orchestrator (server + workers) for the fleet.
#
# Windmill architecture: the server serves the UI/API and writes to Postgres; the
# workers do NOT talk to the server, they connect to the same database and
# take jobs from the queue. Consequence for the fleet: each worker
# needs only a Postgres access (tailnet) and nothing else. A worker that
# falls (sleep, wifi, reboot) resumes on return, with no local state to reconcile.
#
# On tower: role = "server" (database + server + one local worker).
# On deck / anywhere: role = "worker", dbHost = "100.64.0.3" (tower, tailnet).
#
# The container is the pinned official image (amd64 + arm64): no local
# Rust build, and all the script runtimes (python, node, bun, go) are in
# the image, not on the host.
let
  cfg = config.services.windmillFleet;
  image = "ghcr.io/windmill-labs/windmill:${cfg.version}";
  stateDir = "/var/lib/windmill";
  # The server hits Postgres locally: the local authentication of
  # services/postgres is `trust` on 127.0.0.1, so no password.
  # The remote workers go through the tailnet, in scram, with the secret.
  dbUrl = host: pass:
    "postgresql://windmill" + (if pass == "" then "" else ":${pass}") + "@${host}:5432/windmill";
in
{
  options.services.windmillFleet = {
    enable = lib.mkEnableOption "Windmill (task orchestrator of the fleet)";

    role = lib.mkOption {
      type = lib.types.enum [ "server" "worker" ];
      default = "worker";
      description = "server: database + UI/API. worker: takes jobs and executes them.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "1.864.1";
      description = "Tag of the ghcr.io/windmill-labs/windmill image (pinned, never `main`).";
    };

    workerGroup = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Worker group: a script can require `<group>` to go on this machine.";
    };

    workers = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Simultaneous jobs on this node (NUM_WORKERS).";
    };

    dbHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Postgres host. `127.0.0.1` for the server, `100.64.0.3` (tower on the tailnet) for a remote worker.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8010";
      description = "Public URL of the server (links and CORS).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8010;
      description = "Server listen port (8000 is taken by audiobookshelf on tower).";
    };

    expose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Declare the Pangolin (SSO) resource windmill.marcpartensky.com toward 127.0.0.1:8010.";
    };

    noAuth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        NO_AUTH=true: Windmill no longer asks for a login and serves everything as
        superadmin. To enable ONLY behind a proxy that already authenticates
        (Pangolin SSO). Windmill's application OIDC is an Enterprise
        feature: in CE, build_oauth_clients() and list_logins() are
        stubs ("Implementation is not open source"), so wiring Zitadel
        INTO Windmill is not possible without a license.
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
          # In 1.864.1 the pull filters on worker_ping.custom_tags, NOT on
          # worker_group: without WORKER_TAGS, a job `?tag=<group>` stays in
          # the queue indefinitely. So we advertise the group AND the languages.
          WORKER_TAGS = "${cfg.workerGroup},bash,python3";
          NUM_WORKERS = toString cfg.workers;
          BASE_INTERNAL_URL = cfg.baseUrl;
        };
      volumes = [ "${stateDir}:/tmp/windmill" ];
      # `host` so that the server (8000) and the workers (Postgres) reach the
      # machine's loopback without extra podman NAT.
      extraOptions = [ "--network=host" ];
      # The container runs as root: the image writes to /tmp/windmill (mounted).
    };

    # Database + role + tailnet access: only on the server.
    systemd.services.windmillFleet-db = lib.mkIf (cfg.role == "server") {
      description = "Windmill: Postgres roles + password (idempotent)";
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
        # TCP loopback: the local authentication there is `trust` (the unix
        # socket, for its part, is in `peer`: a `psql -U postgres` via socket is
        # refused, experienced on the first switch).
        PSQL="psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -q"
        # Windmill requires two group roles (NOLOGIN) that its docker
        # entrypoint normally creates: without them the first migration fails
        # on `role "windmill_admin" does not exist`.
        for role in windmill_admin windmill_user; do
          if [ "$($PSQL -d postgres -tAc "select 1 from pg_roles where rolname='$role'")" != "1" ]; then
            $PSQL -d postgres -c "create role $role nologin"
          fi
          $PSQL -d postgres -c "grant $role to windmill"
        done
        $PSQL -d windmill -c "GRANT ALL ON SCHEMA public TO windmill_admin" \
                           -c "GRANT ALL ON SCHEMA public TO windmill_user"
        # psql -f via a temporary file: `-c` does NOT interpret the
        # psql variables (`:'pw'` goes out as-is and breaks with a syntax error,
        # experienced), and the password must not appear in the
        # command line. Doubling the single quotes goes through a variable
        # (a literal pair of quotes would be the escaping of the Nix string).
        umask 077
        tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
        q="'"
        pw="$(cat ${config.sops.secrets."windmill_pg_password".path})"
        # The double-quote prefix before the brace is the Nix escaping that
        # makes the interpolation literal (this is bash, not Nix).
        printf "alter role windmill with login password '%s';\n" "''${pw//$q/$q$q}" > "$tmp"
        $PSQL -d postgres -f "$tmp"
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
    };

    # The server applies its migrations at startup: the roles must
    # exist before, otherwise it loops (start-limit-hit).
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

    # The Windmill workers do not talk to the server: they read the queue in
    # Postgres. Hence the listening outside loopback, closed three times: firewall
    # (5432 on tailscale0 only), pg_hba (role windmill / database windmill /
    # scram, from 100.64.0.0/10), and the WireGuard tailnet itself.
    services.postgresql.settings.listen_addresses = lib.mkIf (cfg.role == "server") "*";

    # 5432 reachable by the tailnet nodes only (WireGuard), and the
    # only role authorized remotely is `windmill` on the `windmill` database.
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
