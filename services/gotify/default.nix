# services/gotify/default.nix
{
  pkgs,
  config,
  lib,
  ...
}: {
  sops.secrets = {
    "gotify/admin_password" = {
      key = "gotify_admin_password";
    };
    "gotify/db_password" = {
      key = "gotify_db_password";
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
    package = pkgs.gotify-server;
    stateDirectoryName = "gotify";

    environment = {
      GOTIFY_SERVER_PORT = "8070";
      GOTIFY_DATABASE_DIALECT = "postgres";
      GOTIFY_DEFAULTUSER_NAME = "admin";
      GOTIFY_PASSSTRENGTH = "10";
    };

    environmentFiles = [
      config.sops.templates."gotify.env".path
    ];
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
}
