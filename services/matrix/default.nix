# services/matrix/default.nix
# Serveur Matrix classique (Synapse), pont WhatsApp : ../matrix-whatsapp
{
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
    after = ["mautrix-whatsapp.service" "mautrix-signal.service" "matrix-synapse-db.service"];
    wants = ["mautrix-whatsapp.service" "mautrix-signal.service"];
    requires = ["matrix-synapse-db.service"];
    # mkBefore : tourne avant le --generate-keys du module
    preStart = lib.mkBefore ''
      if [ ! -f ${dataDir}/secrets.yaml ]; then
        echo "registration_shared_secret: $(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${dataDir}/secrets.yaml
        chmod 600 ${dataDir}/secrets.yaml
      fi
    '';
  };

  # Listener par défaut du module : 127.0.0.1:8008 (client + federation, x_forwarded).
  # Pas de port firewall à ouvrir : newt/Pangolin tourne sur tower et tape en local.
  # Exposition publique à faire côté Pangolin : matrix.marcpartensky.com -> http://127.0.0.1:8008
}
