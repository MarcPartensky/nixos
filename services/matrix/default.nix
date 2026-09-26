# services/matrix/default.nix
# Serveur Matrix classique (Synapse), pont WhatsApp : ../matrix-whatsapp
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
      # ATTENTION : server_name ne peut plus être changé après le premier démarrage
      server_name = "matrix.marcpartensky.com";
      public_baseurl = "https://matrix.marcpartensky.com/";
      report_stats = false;
      max_upload_size = "100M";
      # inscription publique fermée : les comptes se créent avec
      # sudo matrix-synapse-register_new_matrix_user -u <user> -a
      # TCP obligatoire : le service tourne avec PrivateUsers=true, ce qui
      # casse l'auth peer par socket Unix (UID mappé). 127.0.0.1 est trust
      # (cf. services/postgres) et déclenche la dépendance postgresql.target
      # du module synapse.
      database.args.host = "127.0.0.1";
    };
    # registration_shared_secret hors du store nix, généré au 1er démarrage (preStart ci-dessous)
    # TODO : migrer vers sops si une clé age devient accessible à hermes
    extraConfigFiles = ["${dataDir}/secrets.yaml"];
  };

  # BDD locale : postgres de tower est en auth trust sur localhost
  # (cf. services/postgres), donc pas de mot de passe à gérer.
  # Le module synapse attend postgresql.target tout seul (host = 127.0.0.1).
  services.postgresql = {
    ensureUsers = [
      {
        name = "matrix-synapse";
        # pas d'ensureDBOwnership ici : la DB est créée par le oneshot
        # ci-dessous avec le OWNER (ensureDatabases ne gère pas la collation)
      }
    ];
  };

  # Synapse EXIGE une DB en collation C (sinon IncorrectDatabaseSetup au boot)
  # et ensureDatabases ne permet pas de la spécifier : création idempotente ici.
  # Connexion par socket en peer (user postgres local, pas de PrivateUsers ici).
  systemd.services.matrix-synapse-db = {
    description = "Création de la base matrix-synapse (collation C)";
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
    # Les bridges génèrent leur registration dans leur propre preStart :
    # synapse doit démarrer APRÈS eux sinon app_service_config_files pointe sur
    # un fichier qui n'existe pas encore et synapse refuse de démarrer.
    # (mautrix-discord gère ça tout seul via mautrix-discord-registration.)
    after = ["mautrix-whatsapp.service" "mautrix-signal.service" "mautrix-linkedin.service" "matrix-synapse-db.service"];
    wants = ["mautrix-whatsapp.service" "mautrix-signal.service" "mautrix-linkedin.service"];
    requires = ["matrix-synapse-db.service"];
    # mkBefore : tourne avant le --generate-keys du module
    preStart = lib.mkBefore ''
      if [ ! -f ${dataDir}/secrets.yaml ]; then
        echo "registration_shared_secret: $(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${dataDir}/secrets.yaml
        chmod 600 ${dataDir}/secrets.yaml
      fi
    '';
  };

  # Compte Matrix du bot Hermes (@hermes) : créé/mis à jour de façon idempotente.
  # register_new_matrix_user lit le shared secret (secrets.yaml, root only) ;
  # mot de passe et token d'accès restent hors du store nix :
  #   - mot de passe : /var/lib/matrix-synapse/hermes-bot-password (root)
  #   - token        : /var/lib/hermes/.hermes/matrix-token (hermes, 0600)
  # Le token sert ensuite de MATRIX_ACCESS_TOKEN pour le gateway hermes
  # (cf. services/hermes).
  systemd.services.matrix-synapse-register-hermes = {
    description = "Création du compte Matrix @hermes (bot Hermes) + token d'accès";
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

      # --exists-ok : ne casse pas si le compte existe déjà
      for _ in 1 2 3 4 5; do
        ${config.services.matrix-synapse.package}/bin/register_new_matrix_user \
          -u hermes -p "$PASS" --exists-ok --no-admin \
          -c ${config.services.matrix-synapse.configFile} \
          -c ${dataDir}/secrets.yaml \
          http://127.0.0.1:8008/ && break
        sleep 2
      done

      # Token d'accès stable (device "Hermes Agent"), créé une seule fois.
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

  # Listener par défaut du module : 127.0.0.1:8008 (client + federation, x_forwarded).
  # Pas de port firewall à ouvrir : newt/Pangolin tourne sur tower et tape en local.
  # Exposition publique à faire côté Pangolin : matrix.marcpartensky.com -> http://127.0.0.1:8008
}
