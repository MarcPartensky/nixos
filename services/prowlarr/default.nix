{ pkgs, ...}:
{
  services.prowlarr = {
    enable = true;
    settings = {
      server = {
        port = 8087;
      };
    };
  };
}
