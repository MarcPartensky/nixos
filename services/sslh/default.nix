{ pkgs, lib, ... }:
{
  services.sslh = {
    enable = true;
    method = "fork"; # one process per connection, simple and robust for personal use
    listenAddresses = [ "0.0.0.0" "[::]" ];
    port = 443; # sslh takes over port 443
    settings = {
      # classic ssh to local port 22
      protocols = [
        {
          name = "ssh";
          host = "localhost";
          port = 22;
        }
        {
          name = "tls";
          host = "localhost";
          port = 8443; # Traefik no longer listens on 443 but on 8443
        }
      ];
    };
  };
}
