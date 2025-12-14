{ pkgs, ... }:
{
  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    config = {
      DOMAIN = "https://vault.marcpartensky.com";
      SIGNUPS_ALLOWED = false;
      DATABASE_URL = "psql://vaultwarden:vaultwardenpassword@localhost:5432/vaultwarden";
    };
  };

}
