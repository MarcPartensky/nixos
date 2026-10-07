{
  config,
  lib,
  pkgs,
  ...
}:

# Serveur de livres audio et podcasts. Bibliothèque sous /srv/media (dataset
# ZFS partagé, cf. services/media : /home/marc/media est banni pour les
# services car systemd-tmpfiles y échoue, "Detected unsafe path transition").
{
  # Clé API audiobookshelf (créée dans Settings > Users, compte hermes) : dans
  # secrets/audiobookshelf.yml (fichier sops dédié, common.yml/tower.yml ne
  # sont pas éditables par hermes sans la clé age privée). Pas encore
  # consommée par un service : disponible pour un futur MCP ou script.
  sops.secrets."audiobookshelf_api_key" = {
    sopsFile = ../../secrets/audiobookshelf.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  services.audiobookshelf = {
    enable = true;
    host = "0.0.0.0";
    port = 8000;
  };

  users.users.audiobookshelf.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    "d /srv/media/audiobooks 2775 root media -"
    "d /srv/media/podcasts 2775 root media -"
  ];

  networking.firewall.allowedTCPPorts = [ 8000 ]; # interface web, LAN uniquement

  # Exposition publique via Pangolin (newt, site "tower") : audiobookshelf.marcpartensky.com
  # -> 127.0.0.1:8000. Même schéma que jellyfin : `proxy-resources` + `protocol`
  # (le Pangolin de ce VPS ignore silencieusement `public-resources`/`mode`,
  # cf. services/newt). Pas d'auth Pangolin : audiobookshelf a sa propre auth.
  services.newt.blueprint.proxy-resources.audiobookshelf = {
    name = "audiobookshelf";
    protocol = "http";
    full-domain = "audiobookshelf.marcpartensky.com";
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8000;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8000;
          path = "/healthcheck";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };
}
