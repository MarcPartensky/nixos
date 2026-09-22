{
  pkgs,
  config,
  lib,
  ...
}: {
  environment.systemPackages = [pkgs.nextcloud33];

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
    listen = [
      {
        addr = "0.0.0.0";
        port = 8083;
        # locations."= /.well-known/openid-configuration".extraConfig = ''
        #   rewrite ^ /index.php$request_uri last;
        # '';
      }
    ];
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION NEXTCLOUD
  # ---------------------------------------------------------------------------
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud33;

    hostName = "localhost";

    autoUpdateApps.enable = false;
    appstoreEnable = false;
    configureRedis = true;

    settings = {
      auth.bruteforce.protection.enabled = false;
      trusted_domains = [
        "localhost"
        "127.0.0.1"
        "192.168.1.44"
        "cloud.vps.marcpartensky.com"
        "cloud.marcpartensky.com"
      ];
      # Si Traefik est en HTTPS et Nextcloud en HTTP derrière :
      overwriteprotocol = "https";
      overwritecondaddr = "^127\\.0\\.0\\.1$"; # l'overwrite ne s'applique qu'aux requêtes venant du reverse proxy
      trusted_proxies = ["127.0.0.1"];
    };

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

    extraApps = {
      inherit
        (config.services.nextcloud.package.packages.apps)
        news
        contacts
        tasks
        calendar
        deck
        memories
        notes
        ;
      oidc = pkgs.fetchNextcloudApp {
        url = "https://github.com/H2CK/oidc/releases/download/2.3.1/oidc-2.3.1.tar.gz";
        hash = "sha256-zfdZSUwV8VZ5qq7rwN/G4cSfTbuutaK+yJ6g8556yOQ=";
        license = "agpl3Plus";
      };
    };
    extraAppsEnable = true;
  };

  systemd.services.nextcloud-cron.path = [pkgs.procps];
  systemd.services.nextcloud-setup = {
    path = [pkgs.procps];
    serviceConfig = {
      # Change cette valeur pour forcer un re-run au prochain switch : ré-active
      # les apps de extraApps (fix 2026-09-22 : calendar déclaré mais jamais
      # activé, tables oc_calendars absentes -> erreurs 500 CalDAV).
      Environment = ["NC_SETUP_FORCE_RUN=20260922"];
      # app:enable ne lance PAS les migrations : sans upgrade ensuite, les
      # tables des apps (oc_calendars...) ne sont jamais créées.
      ExecStartPost = "${config.services.nextcloud.occ}/bin/nextcloud-occ upgrade";
    };
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION BASE DE DONNÉES (PostgreSQL)
  # ---------------------------------------------------------------------------
  services.postgresql = {
    enable = true;

    ensureDatabases = ["nextcloud"];
    ensureUsers = [
      {
        name = "nextcloud";
        ensureDBOwnership = true;
      }
    ];

    # Authentification "Peer" via Socket
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE    USER        METHOD
      local   nextcloud   nextcloud   peer
      local   all         all         peer
    '';
  };
}
