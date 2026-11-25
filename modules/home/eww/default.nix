{ pkgs, ... }:

{
  programs.eww = {
    enable = true;
    package = pkgs.eww;
    configDir = ./.; # It will take all the files in the current directory
  };
}
