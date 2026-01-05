{ pkgs, home-manager, ... }:

let
  wallpapers = pkgs.fetchFromGitHub {
    owner = "marcpartensky";
    repo = "wallpapers";
    rev = "master"; # tu peux mettre un commit SHA précis pour la reproductibilité
    sha256 = "sha256-byN9lbt0ErhCLPV8avfpoMlEbqVEn4HLCi0vWOISri8="; # remplacer après premier build avec nix
  };
  wallpapersDir = "/home/marc/.local/share/wallpapers";
in
{
  # ---------------------------------------
  # Packages utilisateur
  # ---------------------------------------
  home.packages = with pkgs; [
    wpaperd
  ];

  # ---------------------------------------
  # Copier les wallpapers dans le home
  # ---------------------------------------
  home.file.".local/share/wallpapers".source = wallpapers;

  # ---------------------------------------
  # Configuration de wpaperd
  # ---------------------------------------
  home.file.".config/wpaperd/config.toml".text = ''
    [default]
    path = "${wallpapers}"
    duration = "6m"

    [eDP-1]
    path = "${wallpapers}"
    duration = "5m"
    # apply-shadow = true
  '';

  # ---------------------------------------
  # Service wpaperd
  # ---------------------------------------
  systemd.user.services.wpaperd = {
    Unit.Description = "wpaperd wallpaper daemon";
    Unit.After = [ "graphical-session.target" ];
    Service.Type = "simple";
    Service.ExecStart = "${pkgs.wpaperd}/bin/wpaperd";
    Service.Restart = "always";
    Install.WantedBy = [ "default.target" ];
  };
}

