{ pkgs, lib, ...}:
{
  services.traefik = {
    enable = true;

    # Your dashboard's domain name
    dynamicConfigFile = ./dynamic.toml;

    # Static configuration
    staticConfigOptions = {
      entryPoints = {
        web = {
          address = ":80";
          # Force HTTP -> HTTPS redirection for everyone
          http.redirections.entryPoint = {
            to = "websecure";
            scheme = "https";
          };
        };
        websecure.address = ":443";
      };

      api = {
        dashboard = true;
        insecure = true; # no port 8080 exposed, goes through traefik.marcpartensky.com
      };

    # providers = {
    #   # If you want to keep the config files (instead of the docker provider)
    #   file = {
    #     directory = "/srv/traefik/config";
    #     watch = true;
    #   };
    # };

      certificatesResolvers = {
        letsencrypt = {
          acme = {
            email = "marc.partensky@proton.me";
            # can maybe be replaced by pangolin
            storage = lib.mkDefault "/var/lib/traefik/acme.json";
            httpChallenge.entryPoint = "web";
          };
        };
      };
    };
  };

  # # Reverse proxy to the Traefik dashboard
  # services.traefik.dynamicConfigFile = pkgs.writeText "traefik_dynamic.toml" ''
  #   [http.routers]
  #     [http.routers.api]
  #       rule = "Host(`traefik.marcpartensky.com`)"
  #       entryPoints = ["web"]
  #       service = "api@internal"
  # '';


  # For automatic HTTPS
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "marc.partensky@proton.me";

  # If you want to store your local config files
  systemd.tmpfiles.rules = [
    "d /srv/traefik 0755 root root -"
  ];
}
