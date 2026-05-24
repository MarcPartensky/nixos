{ pkgs, config, ... }:

{

  sops.secrets."postgres_crt" = {
    sopsFile = ../../secrets/common.yml;
    owner    = "postgres";
    path     = "/var/lib/postgresql/server.crt";
  };
  sops.secrets."postgres_key" = {
    sopsFile = ../../secrets/common.yml;
    owner    = "postgres";
    mode     = "0600";
    path     = "/var/lib/postgresql/server.key";
  };
  
  services.postgresql = {
    enable = true;
    settings = {
      ssl_cert_file = config.sops.secrets."postgres_crt".path;
      ssl_key_file  = config.sops.secrets."postgres_key".path;
    };


    # ensureDatabases = [ "vaultwarden" ];

    ensureUsers = [
      {
        name = "root";
        ensureClauses = { superuser = true; login = true; };
        # Password setting via Nix is complex, usually handled manually or via socket auth
      }
    ];


    # Authentification (locale et localhost)
    authentication = pkgs.lib.mkOverride 10 ''
      # type database  DBuser  auth-method
      local all all trust

      # IPv4 localhost
      host all all 127.0.0.1/32 trust

      # IPv6 localhost
      host all all ::1/128 trust
    '';

    # # Script SQL initial pour créer utilisateurs et droits
    # initialScript = pkgs.writeText "init.sql" ''
    #   CREATE USER root WITH LOGIN PASSWORD 'rootpassword' SUPERUSER;
    #
    #   -- Nextcloud
    #   CREATE USER nextcloud WITH LOGIN PASSWORD 'nextcloudpassword';
    #   GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
  };

  # services.postgresqlBackup = {
  #   enable = true;
  #   location = "/root/backup/nextcloud";
  #   databases = [ "nextcloud" ];
  #   # time to start backup in systemd.time format
  #   startAt = "*-*-* 5:00:00";
  # };
}

