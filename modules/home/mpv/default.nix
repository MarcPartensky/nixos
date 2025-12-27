{ pkgs, ... }:
{
  programs.mpv = {
    enable = true;
    config = {
      ao = "pipewire"; # Force l'utilisation de pipewire
    };
  };
}
