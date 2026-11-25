# services/shlink/default.nix
# Shlink (github.com/shlinkio/shlink): self-hosted URL shortener,
# full v3 REST server (short URLs, visits, tags, domains, redirect rules).
# Exposed on s.marcpartensky.com.
#
# Architecture choice (see also services/shlink-mcp):
#   - engine in an OCI container (no nixpkgs package: never packaged),
#     same pattern as reactive-resume / open-notebook;
#   - --network=host: the app must reach Postgres at 127.0.0.1:5432 with the
#     "trust/md5 loopback" convention of the rest of tower; the application port
#     (8097) stays closed on the firewall, only the Pangolin resource exposes it;
#   - dedicated Postgres (role + `shlink` database), sops password aligned by a
#     oneshot, like reactive-resume;
#   - Pangolin SSO DELIBERATELY DISABLED: short links must
#     resolve for anyone (a 302 to Zitadel would break any shared
#     link). API protection is the Shlink API key, not the proxy;
#     the Shlink server has no web UI anyway.
#
# Not covered here: visit geolocation, which requires a GeoLite2
# license key (MaxMind account, non-FOSS base). Then add
# GEOLITE_LICENSE_KEY in the env template below; without it Shlink
# starts normally, only the country/city stats stay empty.
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
  # FLAT NAMES deliberately: a name with a slash (`shlink/db_password`) causes
  # a subfolder /run/secrets/<n>/ to be created as drwxr-x--x root:keys, which the
  # `postgres` user cannot traverse (nor read the file): the oneshot
  # below exited with "cat: Permission denied", the role stayed without a
  # password and the container died on "Error updating database".
  sops.secrets.shlink_db_password = {
    key = "shlink_db_password";
    sopsFile = ../../secrets/shlink.yml;
    # Read by shlink-db-password.service (User=postgres).
    owner = "postgres";
  };

  # Shlink API key: serves both as INITIAL_API_KEY on first startup
  # and as credential to the MCP (services/shlink-mcp, which runs as user hermes).
  sops.secrets.shlink_api_key = {
    key = "shlink_api_key";
    sopsFile = ../../secrets/shlink.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  # Container env: rendered decrypted at activation (never in the store).
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

  # ── Dedicated Postgres database ───────────────────────────────────────────────
  services.postgresql = {
    ensureDatabases = ["shlink"];
    ensureUsers = [
      {
        name = "shlink";
        ensureDBOwnership = true;
      }
    ];
    # mkOverride 10: concatenates instead of replacing the rules of the other
    # modules (postgres, reactive-resume, vaultwarden, gitea...).
    authentication = lib.mkOverride 10 ''
      host    shlink  shlink  127.0.0.1/32  md5
    '';
  };

  # Aligns the role's password with the sops secret (ensureUsers does not set
  # one). Runs before the container, replayable on each switch.
  #
  # `postgresql-setup.service` is required EXPLICITLY: it creates the role and the
  # database (ensureUsers/ensureDatabases) but runs as a separate unit,
  # restarted by the switch. Being satisfied with `after = postgresql.service` is
  # not enough when postgres is already active: that dependency is a no-op
  # job, so the oneshot could start before the role was created and exit
  # with "ERROR: role "shlink" does not exist" (experienced on the first switch).
  systemd.services.shlink-db-password = {
    description = "Aligns the postgres role shlink password with the sops secret";
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

  # ── Container data ───────────────────────────────────────────────
  # 0777: the internal uid of the shlinkio/shlink image is not guaranteed
  # (the image runs as non-root since v4) and the volume must stay
  # writable whatever that uid is. Nothing sensitive inside (no SQLite
  # since Postgres, only the possible GeoLite downloads and the locks).
  systemd.tmpfiles.rules = [
    "d /var/lib/shlink 0777 root root -"
    "d /var/lib/shlink/data 0777 root root -"
  ];

  # ── Container ──────────────────────────────────────────────────────────
  virtualisation.oci-containers.containers.shlink = {
    image = "docker.io/shlinkio/shlink:stable";
    autoStart = true;
    volumes = ["/var/lib/shlink/data:/etc/shlink/data"];
    environmentFiles = [config.sops.templates."shlink.env".path];
    # No --health-cmd: the image guarantees neither curl nor wget, and a
    # permanently failing healthcheck makes the container "unhealthy" without
    # informing anyone. The real health is checked by Pangolin on
    # /rest/health (see the resource below), which is the endpoint Shlink
    # documents for that.
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

  # ── Public exposure (Pangolin/newt) ────────────────────────────────
  # `proxy-resources` + `protocol` schema (the one that works on this
  # controller). auth.sso-enabled = false: indispensable for the
  # /<slug> redirects to be public. Healthcheck on /rest/health, which
  # answers 200 without an API key (dedicated health endpoint).
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

  # ── Backup ─────────────────────────────────────────────────────────
  # Tower's daily Postgres dump covered nextcloud only: the
  # links live in the database, so without this a lost disk = all links lost.
  services.postgresqlBackup.databases = lib.mkAfter ["shlink"];

  # ── Safeguards ─────────────────────────────────────────────────────────
  assertions = [
    {
      # --network=host exposes 8097 on all interfaces: only the firewall
      # prevents direct LAN access (the API has only a key, no IP allowlist).
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "shlink: port ${toString port} must not be open on the firewall (exposure only via Pangolin/newt).";
    }
  ];
}
