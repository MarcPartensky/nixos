{ pkgs, ...}:
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


  # Pour HTTPS automatique
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "marc.partensky@proton.me";

  # Si tu veux stocker tes fichiers de conf locaux
  systemd.tmpfiles.rules = [
    "d /srv/traefik 0755 root root -"
  ];
}
