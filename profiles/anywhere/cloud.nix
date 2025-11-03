{ config, pkgs, inputs, ... }:
let
  traefikDynamic = ./dynamic.toml;  # chemin relatif depuis cloud.nix
  pangolin = inputs.unstable.fosrl-pangolin;
in
{
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

  # Pare-feu
  networking.firewall.allowedTCPPorts = [ 80 443 ];

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
  systemd.services.vaultwarden = {
    description = "Vaultwarden server";
    after = [ "network.target" ];
    wants = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.vaultwarden}/bin/vaultwarden --port 8083'";
      Restart = "on-failure";
      User = "vaultwarden";   # créer l'utilisateur ci-dessous
      Group = "users";
      WorkingDirectory = "/var/lib/vaultwarden";
    };
  };

  # Création de l'utilisateur dédié
  users.users.vaultwarden = {
    isNormalUser = true;
    home = "/var/lib/vaultwarden";
    createHome = true;
    shell = pkgs.bash;
  };



}

