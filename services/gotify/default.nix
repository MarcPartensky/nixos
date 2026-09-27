# services/gotify/default.nix
{
  pkgs,
  config,
  lib,
  inputs,
  ...,
}: {
  sops.secrets = {
    "gotify/admin_password" = {
      key = "gotify_admin_password";
    };
    "gotify/db_password" = {
      key = "gotify_db_password";
      # lu par gotify-db-password.service, qui tourne en User=postgres
      # (gotify lui-même lit le mot de passe via le template sops, pas ce fichier)
      owner = "postgres";
    };
  };

  sops.templates."gotify.env" = {
    content = ''
      GOTIFY_DEFAULTUSER_PASS=${config.sops.placeholder."gotify/admin_password"}
      GOTIFY_DATABASE_CONNECTION=host=localhost port=5432 user=gotify dbname=gotify password=${config.sops.placeholder."gotify/db_password"} sslmode=disable
    '';
  };

  services.gotify = {
    enable = true;
    package = inputs.unstable.gotify-server;
    stateDirectoryName = "gotify";

    environment = {
      GOTIFY_SERVER_PORT = "8070";
      GOTIFY_DATABASE_DIALECT = "postgres";
      GOTIFY_DEFAULTUSER_NAME = "admin";
      GOTIFY_PASSSTRENGTH = "10";

      # OIDC / Zitadel SSO
      GOTIFY_OIDC_ENABLED = "true";
      GOTIFY_OIDC_CLIENT_ID = "392663692992381228";
      GOTIFY_OIDC_CLIENT_SECRET = "";
      GOTIFY_OIDC_ISSUER = "https://auth.marcpartensky.com";
      GOTIFY_OIDC_REDIRECT_URL = "https://gotify.marcpartensky.com/auth/oidc/callback";
      GOTIFY_OIDC_SCOPES = "openid profile email";
      GOTIFY_OIDC_USERNAME_CLAIM = "preferred_username";
      GOTIFY_OIDC_DISPLAY_NAME_CLAIM = "name";
      GOTIFY_OIDC_EMAIL_CLAIM = "email";
    };

    environmentFiles = [
      config.sops.templates."gotify.env".path
    ];
  };

  # gotify dépend de postgres : sans ces réglages il crash-loopait quand un
  # switch redémarre postgresql (RestartSec=100ms par défaut, 5 essais, puis
  # start-limit-hit avant que postgres n'accepte de nouveau les connexions).
  systemd.services.gotify-server = {
    after = ["postgresql.service"];
    wants = ["postgresql.service"];
    unitConfig = {
      StartLimitIntervalSec = 60;
      StartLimitBurst = 10;
    };
    serviceConfig = {
      RestartSec = "2s";
    };
  };

  # MÊME BUG QUE VAULTWARDEN (vérifié 25/09/2026 en rejouant le binaire à la
  # main) : ensureUsers crée le rôle postgres `gotify` SANS mot de passe, alors
  # que le pg_hba effectif exige md5/scram pour ce rôle (services.postgresql.
  # authentication est un types.lines : tous les modules se concatènent et la
  # règle `host gotify gotify 127.0.0.1/32 md5` passe AVANT le
  # `host all all 127.0.0.1/32 trust` générique). Symptôme : gotify-server sort
  # en 64 ms avec status=2 et
  #   failed SASL auth: FATAL: password authentication failed for user "gotify"
  # puis start-limit-hit. Fix : aligner le rôle sur le secret sops déjà utilisé
  # par GOTIFY_DATABASE_CONNECTION. Idempotent, rejoué à chaque activation.
  systemd.services.gotify-db-password = {
    description = "Aligne le mot de passe du rôle postgres gotify sur le secret sops";
    wantedBy = ["multi-user.target"];
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    before = ["gotify-server.service"];
    requiredBy = ["gotify-server.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -v pw="$(cat ${config.sops.secrets."gotify/db_password".path})" <<'SQL'
      ALTER ROLE gotify WITH PASSWORD :'pw';
      SQL
    '';
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = ["gotify"];
    ensureUsers = [
      {
        name = "gotify";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE  USER     ADDRESS    METHOD
      host    gotify    gotify   127.0.0.1/32  md5
      local   all       all                 peer
    '';
  };

  # Exposition via Pangolin (newt blueprint) -> gotify.marcpartensky.com
  services.newt.blueprint.proxy-resources.gotify = {
    name = "Gotify notifications";
    protocol = "http";
    full-domain = "gotify.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8070;
        method = "http";
      }
    ];
  };
}
