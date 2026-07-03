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
      ROCKET_PORT = 8083;
    };
  };
}
