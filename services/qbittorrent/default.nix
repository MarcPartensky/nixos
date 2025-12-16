{ pkgs, ... }:
{
    # configuration.nix
  services.qbittorrent = {
    enable = true;
    webuiPort = 8084;
    torrentingPort = 8085;
  };
}
