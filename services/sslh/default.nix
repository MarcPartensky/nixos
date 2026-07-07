{ pkgs, lib, ... }:
{
  services.sslh = {
    enable = true;
    method = "fork"; # un process par connexion, simple et robuste pour un usage perso
    listenAddresses = [ "0.0.0.0" "[::]" ];
    port = 443; # sslh prend la main sur le 443
    settings = {
      # ssh classique vers le port 22 local
      protocols = [
        {
          name = "ssh";
          host = "localhost";
          port = 22;
        }
        {
          name = "tls";
          host = "localhost";
          port = 8443; # Traefik n'écoute plus sur 443 mais sur 8443
        }
      ];
    };
  };
}
