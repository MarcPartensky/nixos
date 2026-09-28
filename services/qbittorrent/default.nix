{
  lib,
  pkgs,
  ...
}: {
  # configuration.nix
  services.qbittorrent = {
    enable = true;
    webuiPort = 8084;
    torrentingPort = 8085;
    serverConfig = {
      LegalNotice.Accepted = true; # Souvent nécessaire pour le démarrage
      # Média partagé (cf. services/media) : les torrents atterrissent dans le
      # MÊME dataset que la bibliothèque, ce qui permet aux *arr d'importer par
      # lien dur (Radarr/Sonarr) au lieu de recopier, et donc de laisser le
      # seed actif sans doubler l'espace disque. Les sous-dossiers par catégorie
      # (radarr/, sonarr/) sont créés par les *arr eux-mêmes.
      BitTorrent = {
        "Session\\DefaultSavePath" = "/srv/media/downloads";
        "Session\\TempPathEnabled" = "true";
        "Session\\TempPath" = "/srv/media/downloads/incomplete";
      };
      Preferences = {
        WebUI = {
          Username = "marc"; # Remplacez par le nom d'utilisateur souhaité
          AuthSubnetWhitelistEnabled = true;
          AuthSubnetWhitelist = "127.0.0.1/32, ::1/128";
          # Password_PBKDF2 =
          #   "@ByteArray(wUQ/AMQATShMtwm8UpQfGQ==:8bUAN8WTM5IEQ3qzDjYkiA4Rj/23RxnVfZLHk0M1REMyfH7vKLY7RwFMmgQf9lyNkr/KOlRvK9MN1s5uKGC7Dg==)";
          # # LocalHostAuth = true; # Optionnel: Peut être utile pour l'accès local
        };
      };
    };
  };

  # Média partagé : les fichiers en cours de téléchargement (puis à l'arrêt,
  # pour le seed) doivent rester lisibles et modifiables par les *arr et par
  # marc. Le module ne pose pas d'UMask, il est donc fixé ici.
  systemd.services.qbittorrent.serviceConfig.UMask = "0002";
}
