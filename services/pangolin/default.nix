{ pkgs, ... }:
{
  services.pangolin = {
    enable = true;
    baseDomain = "marcpartensky.com";
    environmentFile = "/var/lib/pangolin/secret";
  };
}
