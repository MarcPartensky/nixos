{ pkgs, ... }:
{
  services.sonarr = {
    enable = true;
    # openFirewall = true;
    user = "marc";
    group = "users";
    dataDir = "/home/marc/radarr";
    settings = {
      # update.mechanism = "internal";
      server = {
        urlbase = "localhost";
        port = 8006;
        bindaddress = "*";
      };
    };
  };
}
