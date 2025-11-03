{ config, pkgs, inputs, ... }:
let
  traefikDynamic = ./dynamic.toml;  # chemin relatif depuis cloud.nix
  pangolin = inputs.unstable.fosrl-pangolin;
in
{
  networking.firewall = {
    enable = true;                  # active le firewall
    allowedTCPPorts = [ 80 443 8080 8081 8082 8083 ];  # ajoute les ports à ouvrir
    allowedUDPPorts = [ ];          # si besoin pour UDP
  };

  services.traefik = {
    enable = true;

    # Nom de domaine de ton dashboard
    dynamicConfigFile = traefikDynamic;

    # Configuration statique
    staticConfigOptions = {
      entryPoints = {
        web.address = ":80";
        websecure.address = ":443";
      };

      api = {
        dashboard = true;
        insecure = true; # pas de port 8080 exposé, passe par traefik.marcpartensky.com
      };

      # providers = {
      #   # Si tu veux garder les fichiers de config (au lieu du docker provider)
      #   file = {
      #     directory = "/srv/traefik/config";
      #     watch = true;
      #   };
      # };

      certificatesResolvers = {
        letsencrypt = {
          acme = {
            email = "marc.partensky@proton.me";
            storage = "/var/lib/traefik/acme.json";
            httpChallenge.entryPoint = "web";
          };
        };
      };
    };
  };

  # # Reverse proxy vers le dashboard Traefik
  # services.traefik.dynamicConfigFile = pkgs.writeText "traefik_dynamic.toml" ''
  #   [http.routers]
  #     [http.routers.api]
  #       rule = "Host(`traefik.marcpartensky.com`)"
  #       entryPoints = ["web"]
  #       service = "api@internal"
  # '';


  # Pour HTTPS automatique
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "marc.partensky@proton.me";

  # Si tu veux stocker tes fichiers de conf locaux
  systemd.tmpfiles.rules = [
    "d /srv/traefik 0755 root root -"
  ];

  # networking.wireguard.enable = true;
  # networking.wireguard.interfaces = {
  #   wg0 = {
  #     privateKey = "UEKfQ6iKyIWlbkPuD60sqLt1BZ3ceQYUy44PZMczqHw=";       # server or client private key
  #     address = [ "10.0.0.1/24" ];                 # your WG subnet
  #     listenPort = 51820;                           # optional, default 51820
  #     peers = [
  #       {
  #         publicKey = "Jlur6sLameyTQJHdTGcEp9oT3bfCplgCNuSxNJwlzz0=";
  #         allowedIPs = [ "10.0.0.2/32" ];           # peer address
  #         endpoint = "1.2.3.4:51820";               # optional
  #         persistentKeepalive = 25;                 # optional, for NAT
  #       }
  #     ];
  #   };
  # };


  # services.nextcloud = {
  #   enable = true;
  #   hostName = "nextcloud.local";  # pour tests internes, pas besoin de DNS réel
  #   package = pkgs.nextcloud29;     # dernière version stable
  #   https = false;                  # HTTP pour tests VM, tu peux activer HTTPS plus tard
  #   database.createLocally = true;  # SQLite par défaut ou MariaDB/Postgres
  #   configureRedis = true;          # cache optionnel
  #   config.adminpassFile = "/var/lib/nextcloud/adminpass";
  # };

  # services.pangolin = {
  #   enable = true;
  #   package = pkgs.pangolin;   # ou ton overlay Nix
  #   port = 8082;                # interne, Traefik redirige
  # };

  # Vaultwarden service
  services.vaultwarden = {
    enable = true;
  
    # Répertoire de backup (optionnel)
    backupDir = "/var/local/vaultwarden/backup";
  
    # Variables d'environnement sensibles
    environmentFile = "/var/lib/vaultwarden/vaultwarden.env";
  
    config = {
      DOMAIN = "https://vault.vps.marcpartensky.com";
      SIGNUPS_ALLOWED = false;
  
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8083;   # port interne pour Traefik
      ROCKET_LOG = "critical";
  
      # SMTP (optionnel)
      # SMTP_HOST = "127.0.0.1";
      # SMTP_PORT = 25;
      # SMTP_SSL = false;
      # SMTP_FROM = "admin@marcpartensky.com";
      # SMTP_FROM_NAME = "Vaultwarden";
    };
  };




}

