{ config, pkgs, ... }:

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

  # systemd.services.navidrome = {
  #   serviceConfig = {
  #     StateDirectory = "navidrome";
  #     DeviceAllow = "";
  #     LockPersonality = true;
  #     PrivateDevices = true;
  #     RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
  #   };
  # };

  # networking.firewall.allowedTCPPorts = [ 4533 ];
}
