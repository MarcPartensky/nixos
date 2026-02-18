{pkgs, ...}: {
  services.flaresolverr = {
    enable = true;
    settings = {
      server = {
        port = 8089;
      };
    };
  };
}
