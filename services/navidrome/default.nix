{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      # Média partagé : /srv/media/music (groupe `media`, cf. services/media),
      # et non plus /home/marc/media/music qui obligeait à donner à navidrome un
      # droit de traversée sur le home de marc (0700) et le faisait scanner une
      # bibliothèque vide.
      MusicFolder = "/srv/media/music";
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
      # La musique n'est plus dans /home : plus besoin de BindPaths ni de
      # traverser le home, le durcissement du module peut rester actif.
      ProtectHome = lib.mkForce true;
    };
  };

  # networking.firewall.allowedTCPPorts = [ 4533 ];
}
