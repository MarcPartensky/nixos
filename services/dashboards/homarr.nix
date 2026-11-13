# Homarr : pas de paquet nixpkgs, donc conteneur podman déclaratif.
# Se configure uniquement dans son UI (SQLite dans /var/lib/homarr).
{
  lib,
  pkgs,
  ...
}: let
  domain = "homarr.marcpartensky.com";
  port = 8675;
  backendPort = 7615;
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/homarr 0770 1000 1000 -"
  ];

  # Homarr exige une clé de chiffrement ; générée une seule fois hors du
  # flake (aucun secret en clair dans git).
  systemd.services.homarr-secret = {
    description = "Clé de chiffrement Homarr (générée une fois)";
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-homarr.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -s /var/lib/homarr/secret.env ]; then
        echo "SECRET_ENCRYPTION_KEY=$(${pkgs.openssl}/bin/openssl rand -hex 32)" > /var/lib/homarr/secret.env
        chmod 0600 /var/lib/homarr/secret.env
      fi
    '';
  };

  virtualisation.oci-containers.containers.homarr = {
    image = "ghcr.io/homarr-labs/homarr:latest";
    ports = [ "127.0.0.1:${toString backendPort}:7575" ];
    volumes = [ "/var/lib/homarr:/appdata" ];
    environmentFiles = [ "/var/lib/homarr/secret.env" ];
    environment = {
      TZ = "America/New_York";
    };
  };

  systemd.services."podman-homarr".after = [ "homarr-secret.service" ];
  systemd.services."podman-homarr".requires = [ "homarr-secret.service" ];

  services.nginx.virtualHosts."${domain}" = {
    listen = [{
      addr = "127.0.0.1";
      port = port;
    }];
    serverName = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString backendPort}";
      proxyWebsockets = true;
    };
  };
}
