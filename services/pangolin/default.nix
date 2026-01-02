{ pkgs, ... }:
{
  nixpkgs.config.permittedInsecurePackages = [
    "pangolin-1.10.3"
  ];
  services.pangolin = {
    enable = true;
    baseDomain = "marcpartensky.com";
    environmentFile = "/var/lib/pangolin/secret";
  };
}
