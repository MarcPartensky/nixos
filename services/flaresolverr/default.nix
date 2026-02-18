{pkgs, ...}: {
  services.flaresolverr = {
    enable = true;
    openFirewall = true;
  };
}
