{ config, pkgs, lib, ... }:

{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      MusicFolder = "/home/marc/media/music";
      # DataFolder = "/var/lib/navidrome/data";
      LogLevel = "info";
      ScanSchedule = "@every 1h";
      TranscodingCacheSize = "500MB";
      DefaultLanguage = "fr";
    };
  };

  systemd.services.navidrome = {
    serviceConfig = {
      StateDirectory = "navidrome";
      DeviceAllow = "";
      LockPersonality = true;
      PrivateDevices = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      ProtectHome = lib.mkForce "read-only";
      BindPaths = [ "/home/marc/media/music" ];
    };
  };

  # /home/marc n'est traversable que par son groupe propriétaire (other::---) :
  # sans `users` en groupe secondaire, l'utilisateur navidrome ne peut pas
  # atteindre /home/marc/media/music et scanne une bibliothèque vide.
  users.users.navidrome.extraGroups = [ "users" ];

  # networking.firewall.allowedTCPPorts = [ 4533 ];
}
