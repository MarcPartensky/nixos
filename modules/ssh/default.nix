{ pkgs, ... }:
{
  home-manager.users.marc = { pkgs, inputs, ... }: {
    programs.ssh = {
      extraConfig = "
        Host rack
          Hostname marcpartensky.com
          Port 42069
          User marc
      ";
    };
  };
}
