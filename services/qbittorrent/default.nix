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
      LegalNotice.Accepted = true; # Often needed for startup
      # Shared media (see services/media): torrents land in the
      # SAME dataset as the library, which lets the *arrs import by
      # hard link (Radarr/Sonarr) instead of copying, and therefore leave the
      # seed active without doubling disk space. The per-category subfolders
      # (radarr/, sonarr/) are created by the *arrs themselves.
      BitTorrent = {
        "Session\\DefaultSavePath" = "/srv/media/downloads";
        "Session\\TempPathEnabled" = "true";
        "Session\\TempPath" = "/srv/media/downloads/incomplete";
      };
      Preferences = {
        WebUI = {
          Username = "marc"; # Replace with the desired username
          AuthSubnetWhitelistEnabled = true;
          AuthSubnetWhitelist = "127.0.0.1/32, ::1/128";
          # Password_PBKDF2 =
          #   "@ByteArray(wUQ/AMQATShMtwm8UpQfGQ==:8bUAN8WTM5IEQ3qzDjYkiA4Rj/23RxnVfZLHk0M1REMyfH7vKLY7RwFMmgQf9lyNkr/KOlRvK9MN1s5uKGC7Dg==)";
          # # LocalHostAuth = true; # Optional: may be useful for local access
        };
      };
    };
  };

  # Shared media: files being downloaded (then at rest,
  # for seeding) must remain readable and writable by the *arrs and by
  # marc. The module does not set a UMask, so it is set here.
  systemd.services.qbittorrent.serviceConfig.UMask = "0002";
}
