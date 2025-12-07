{ pkgs, ... }:
{
  programs.ssh = {
    extraConfig = "
      Host rack
        Hostname marcpartensky.com
        Port 42069
        User marc
    ";
  };
}
