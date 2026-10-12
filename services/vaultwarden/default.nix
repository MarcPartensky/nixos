# services/vaultwarden/default.nix
{
  pkgs,
  config,
  lib,
  ...
}: {
  sops.secrets."vaultwarden/db_password" = {
    key = "vaultwarden_db_password";
    sopsFile = ../../secrets/common.yml;
    # lu par vaultwarden-db-password.service, qui tourne en User=postgres
    # (vaultwarden lui-même lit le mot de passe via le template sops, pas ce fichier)
    owner = "postgres";
  };

  sops.secrets."vaultwarden/admin_token" = {
    key = "vaultwarden_admin_token";
    sopsFile = ../../secrets/common.yml;
  };

  sops.templates."vaultwarden.env" = {
    content = ''
      DATABASE_URL=postgres://vaultwarden:${config.sops.placeholder."vaultwarden/db_password"}@localhost:5432/vaultwarden
      ADMIN_TOKEN=${config.sops.placeholder."vaultwarden/admin_token"}
    '';
  };

  services.postgresql = {
    ensureDatabases = ["vaultwarden"];
    ensureUsers = [
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE     USER         ADDRESS        METHOD
      host    vaultwarden  vaultwarden  127.0.0.1/32   md5
      local   all          all                         peer
    '';
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    environmentFile = config.sops.templates."vaultwarden.env".path;
    config = {
      DOMAIN = "https://vault.marcpartensky.com";
      SIGNUPS_ALLOWED = true;

      WEBSOCKET_ENABLED = true;
      WEBSOCKET_ADDRESS = "0.0.0.0";
      WEBSOCKET_PORT = 3012;

      ROCKET_ADDRESS = "0.0.0.0";
      # 8222 = défaut de vaultwarden. NE PAS revenir à 8083 : c'est le port de
      # nginx Nextcloud (services/nextcloud/default.nix), et les deux sur le même
      # port faisait planter vaultwarden en boucle (NRestarts qui montait, rocket
      # ne peut pas binder). Vérifié le 24/09/2026 : vaultwarden n'était plus
      # joignable depuis que Nextcloud a pris 8083.
      ROCKET_PORT = 8222;
    };
  };

  # Le rôle postgres vaultwarden était créé sans mot de passe par ensureUsers,
  # alors que le pg_hba effectif exige md5 pour ce rôle (services/postgresql.
  # authentication est un types.lines : TOUS les modules se concatènent, et la
  # règle vaultwarden md5 passe avant le "host all all 127.0.0.1/32 trust"
  # générique). Résultat vérifié dans le journal le 24/09/2026 :
  #   FATAL: password authentication failed for user "vaultwarden"
  # -> vaultwarden bouclait (retry ~30 s puis exit 0, Restart=always).
  # Fix : aligner le rôle sur le secret sops que DATABASE_URL utilise déjà
  # (sops.templates."vaultwarden.env"). Idempotent, rejoué à chaque activation.
  systemd.services.vaultwarden-db-password = {
    description = "Aligne le mot de passe du rôle postgres vaultwarden sur le secret sops";
    wantedBy = ["multi-user.target"];
    before = ["vaultwarden.service"];
    requiredBy = ["vaultwarden.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -v pw="$(cat ${config.sops.secrets."vaultwarden/db_password".path})" <<'SQL'
      ALTER ROLE vaultwarden WITH PASSWORD :'pw';
      SQL
    '';
  };

}
