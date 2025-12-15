{ pkgs, ... }:
{
  services.postgresql = {
    ensureDatabases = [ "vaultwarden" ];
    ensureUsers = [
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
        # Since you use 'trust' in authentication below, we don't strictly need a password here
        # provided Nextcloud connects from localhost.
      }
    ];
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    config = {
      DOMAIN = "https://vault.marcpartensky.com";
      SIGNUPS_ALLOWED = true;
      DATABASE_URL = "postgres://vaultwarden:vaultwardenpassword@localhost:5432/vaultwarden";

      WEBSOCKET_ENABLED = true;
      WEBSOCKET_ADDRESS = "0.0.0.0";
      WEBSOCKET_PORT = 3012;
      
      # Serveur HTTP principal
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8083;
    };
  };

}
