{ pkgs, config, lib, ... }:

{
  environment.systemPackages = [ pkgs.nextcloud32 ];

  sops.secrets = {
    # Le nom à gauche (ex: "nextcloud/adminUser") sera le nom du fichier dans /run/secrets/
    # La clé "key" pointe vers la structure dans ton fichier YAML (ex: nextcloud: adminUser: ...)
    
    "nextcloud/admin_user" = {
      owner = "nextcloud"; # Important : Nextcloud doit pouvoir lire ce fichier
      group = "nextcloud";
      key = "nextcloud_admin_user"; 
    };

    "nextcloud/user" = {
      owner = "nextcloud"; # Important : Nextcloud doit pouvoir lire ce fichier
      group = "nextcloud";
      key = "nextcloud_user"; 
    };
    
    "nextcloud/admin_password" = {
      owner = "nextcloud";
      group = "nextcloud";
      key = "nextcloud_admin_password";
    };

    # Mot de passe de la base de données
    "nextcloud/password" = {
      owner = "nextcloud";
      group = "nextcloud";
      key = "nextcloud_password";
    };
  };

  services.nginx.virtualHosts."localhost" = {
    listen = [ { addr = "0.0.0.0"; port = 8081; } ];
  };


  # ---------------------------------------------------------------------------
  # CONFIGURATION NEXTCLOUD
  # ---------------------------------------------------------------------------
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud32;
    
    hostName = "localhost"; 

    autoUpdateApps.enable = true;
    appstoreEnable = true;
    configureRedis = true;

    config = {
      dbtype = "pgsql";
      dbuser = "nextcloud";
      
      # Utilisation du socket Unix (plus performant et sécurisé)
      dbhost = "/run/postgresql"; 
      
      # Injection des secrets via les chemins générés par SOPS
      # user = config.sops.secrets."nextcloud/user".path;
      # adminuser = config.sops.secrets."nextcloud/admin_user";
      adminuser = "root";
      adminpassFile = config.sops.secrets."nextcloud/admin_password".path;
      dbpassFile = config.sops.secrets."nextcloud/password".path;
    };
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION BASE DE DONNÉES (PostgreSQL)
  # ---------------------------------------------------------------------------
  services.postgresql = {
    enable = true;
    
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [{
      name = "nextcloud";
      ensureDBOwnership = true;
    }];

    # Authentification "Peer" via Socket
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE    USER        METHOD
      local   nextcloud   nextcloud   peer
      local   all         all         peer
    '';
  };
}
