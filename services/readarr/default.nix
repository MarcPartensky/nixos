{ pkgs, ... }:
{
  services.readarr = {
    enable = true;
    user = "marc";
    group = "users";
    dataDir = "/home/marc/readarr";
    settings = {
      # update.mechanism = "internal";
      server = {
        urlbase = "localhost";
        port = 8088;
        bindaddress = "*";
      };
    };
  };
}
