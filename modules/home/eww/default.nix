{ pkgs, ... }:

{
  programs.eww = {
    enable = true;
    package = pkgs.eww;
    configDir = ./.; # Il va prendre tous les fichiers du dossier courant
  };
}
