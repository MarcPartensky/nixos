{ pkgs, ... }:

{
  services.postgresql = {
    enable = true;

    # Crée les bases automatiquement
    ensureDatabases = [ "nextcloud" "vaultwarden" ];
    # ensureUsers = [{
    #   name = "nextcloud";
    #   ensurePermissions."DATABASE nextcloud" = "ALL PRIVILEGES";
    # }];


    # Authentification (locale et localhost)
    authentication = pkgs.lib.mkOverride 10 ''
      # type database  DBuser  auth-method
      local all all trust

      # IPv4 localhost
      host all all 127.0.0.1/32 trust

      # IPv6 localhost
      host all all ::1/128 trust
    '';

    # Script SQL initial pour créer utilisateurs et droits
    initialScript = pkgs.writeText "init.sql" ''
      CREATE USER root WITH LOGIN PASSWORD 'rootpassword' SUPERUSER;

      -- Nextcloud
      CREATE USER nextcloud WITH LOGIN PASSWORD 'nextcloudpassword';
      GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;

      -- Vaultwarden
      CREATE USER vaultwarden WITH LOGIN PASSWORD 'vaultwarden';
      GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
    '';
  };

  # services.postgresqlBackup = {
  #   enable = true;
  #   location = "/root/backup/nextcloud";
  #   databases = [ "nextcloud" ];
  #   # time to start backup in systemd.time format
  #   startAt = "*-*-* 5:00:00";
  # };
}

