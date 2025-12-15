{ pkgs, ... }:
{
  services.udiskie = {
    enable = true;
    automount = true;
    notify = true;
    # settings = {};
    tray = "never";
  };
}
