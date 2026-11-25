{ pkgs, home-manager, ... }:

let
  wallpapers = pkgs.fetchFromGitHub {
    owner = "marcpartensky";
    repo = "wallpapers";
    rev = "master"; # you can put a specific commit SHA for reproducibility
    sha256 = "sha256-byN9lbt0ErhCLPV8avfpoMlEbqVEn4HLCi0vWOISri8="; # replace after the first build with nix
  };
  wallpapersDir = "/home/marc/.local/share/wallpapers";
in
{
  # ---------------------------------------
  # User packages
  # ---------------------------------------
  home.packages = with pkgs; [
    wpaperd
  ];

  # ---------------------------------------
  # Copy the wallpapers into the home
  # ---------------------------------------
  home.file.".local/share/wallpapers".source = wallpapers;

  # ---------------------------------------
  # wpaperd configuration
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
  # wpaperd service
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

