# services/matrix/default.nix
# Classic Matrix server (Synapse), WhatsApp bridge: ../matrix-whatsapp
{
  config,
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/matrix-synapse";
in {
  services.matrix-synapse = {
    enable = true;
    settings = {
      # WARNING: server_name can no longer be changed after the first start
      server_name = "matrix.marcpartensky.com";
      public_baseurl = "https://matrix.marcpartensky.com/";
      report_stats = false;
      max_upload_size = "100M";
      # public registration closed: accounts are created with
      # sudo matrix-synapse-register_new_matrix_user -u <user> -a
      # TCP required: the service runs with PrivateUsers=true, which
      # breaks peer auth by Unix socket (mapped UID). 127.0.0.1 is trust
      # (cf. services/postgres) and triggers the postgresql.target dependency
      # of the synapse module.
      database.args.host = "127.0.0.1";
    };
    # registration_shared_secret outside the nix store, generated on the 1st start (preStart below)
    # TODO: migrate to sops if an age key becomes accessible to hermes
    extraConfigFiles = ["${dataDir}/secrets.yaml"];
  };

  # Local DB: tower's postgres is in trust auth on localhost
  # (cf. services/postgres), so no password to manage.
  # The synapse module waits for postgresql.target on its own (host = 127.0.0.1).
  services.postgresql = {
    ensureUsers = [
      {
        name = "matrix-synapse";
        # no ensureDBOwnership here: the DB is created by the oneshot
        # below with the OWNER (ensureDatabases does not handle the collation)
      }
    ];
  };

  # Synapse REQUIRES a DB in collation C (otherwise IncorrectDatabaseSetup at boot)
  # and ensureDatabases does not allow specifying it: idempotent creation here.
  # Peer socket connection (local postgres user, no PrivateUsers here).
  systemd.services.matrix-synapse-db = {
    description = "Creation of the matrix-synapse database (collation C)";
    after = ["postgresql.service" "postgresql-setup.service"];
    requires = ["postgresql.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -tAc "SELECT 1 FROM pg_database WHERE datname='matrix-synapse'" \
        | grep -q 1 \
        || ${pkgs.postgresql}/bin/psql -c "CREATE DATABASE \"matrix-synapse\" OWNER \"matrix-synapse\" LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
    '';
  };

  systemd.services.matrix-synapse = {
    # The bridges generate their registration in their own preStart:
    # synapse must start AFTER them otherwise app_service_config_files points to
    # a file that does not exist yet and synapse refuses to start.
    # (mautrix-discord handles this on its own via mautrix-discord-registration.)
    after = ["mautrix-whatsapp.service" "mautrix-signal.service" "mautrix-linkedin.service" "matrix-synapse-db.service"];
    wants = ["mautrix-whatsapp.service" "mautrix-signal.service" "mautrix-linkedin.service"];
    requires = ["matrix-synapse-db.service"];
    # mkBefore: runs before the module's --generate-keys
    preStart = lib.mkBefore ''
      if [ ! -f ${dataDir}/secrets.yaml ]; then
        echo "registration_shared_secret: $(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${dataDir}/secrets.yaml
        chmod 600 ${dataDir}/secrets.yaml
      fi
    '';
  };

  # Matrix account of the Hermes bot (@hermes): created/updated idempotently.
  # register_new_matrix_user reads the shared secret (secrets.yaml, root only);
  # password and access token stay outside the nix store:
  #   - password: /var/lib/matrix-synapse/hermes-bot-password (root)
  #   - token   : /var/lib/hermes/.hermes/matrix-token (hermes, 0600)
  # The token then serves as MATRIX_ACCESS_TOKEN for the hermes gateway
  # (cf. services/hermes).
  systemd.services.matrix-synapse-register-hermes = {
    description = "Creation of the Matrix account @hermes (Hermes bot) + access token";
    after = ["matrix-synapse.service"];
    requires = ["matrix-synapse.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      PASS_FILE=/var/lib/matrix-synapse/hermes-bot-password
      TOKEN_FILE=/var/lib/hermes/.hermes/matrix-token

      umask 077
      if [ ! -f "$PASS_FILE" ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 24 > "$PASS_FILE"
      fi
      PASS=$(cat "$PASS_FILE")

      # --exists-ok: does not break if the account already exists
      for _ in 1 2 3 4 5; do
        ${config.services.matrix-synapse.package}/bin/register_new_matrix_user \
          -u hermes -p "$PASS" --exists-ok --no-admin \
          -c ${config.services.matrix-synapse.configFile} \
          -c ${dataDir}/secrets.yaml \
          http://127.0.0.1:8008/ && break
        sleep 2
      done

      # Stable access token (device "Hermes Agent"), created only once.
      if [ ! -f "$TOKEN_FILE" ]; then
        RESP=$(${pkgs.curl}/bin/curl -sf -X POST \
          http://127.0.0.1:8008/_matrix/client/v3/login \
          -H 'Content-Type: application/json' \
          -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"hermes\"},\"password\":\"$PASS\",\"initial_device_display_name\":\"Hermes Agent\"}")
        TOKEN=$(printf '%s' "$RESP" | ${pkgs.gnugrep}/bin/grep -o '"access_token":"[^"]*"' | ${pkgs.coreutils}/bin/cut -d '"' -f4)
        test -n "$TOKEN"
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/hermes/.hermes
        printf '%s' "$TOKEN" > "$TOKEN_FILE"
        ${pkgs.coreutils}/bin/chown hermes:hermes "$TOKEN_FILE"
        ${pkgs.coreutils}/bin/chmod 600 "$TOKEN_FILE"
      fi
    '';
  };

  # Default listener of the module: 127.0.0.1:8008 (client + federation, x_forwarded).
  # No firewall port to open: newt/Pangolin runs on tower and hits it locally.
  # Public exposure to be done on the Pangolin side: matrix.marcpartensky.com -> http://127.0.0.1:8008
}
