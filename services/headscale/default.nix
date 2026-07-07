{ pkgs, config, ... }:
{
  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = 8080;
    settings = {
      server_url = "https://headscale.marcpartensky.com";
      dns = {
        magic_dns = true;
        base_domain = "ts.marcpartensky.com";
      };
    };
  };

  environment.systemPackages = [ config.services.headscale.package ];
}
