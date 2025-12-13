{ config, lib, pkgs, ... }:

let
  youtube-app = pkgs.writeShellScriptBin "youtube-app" ''
    # Use existing LibreWolf profile (modify if using non-default profile)
    PROFILE_DIR="$HOME/.librewolf/default"
    
    # Fallback for Flatpak installations
    if [ ! -d "$PROFILE_DIR" ]; then
      PROFILE_DIR="$HOME/.var/app/io.gitlab.librewolf-community/.librewolf/default"
    fi

    # Create dedicated profile if doesn't exist
    if [ ! -d "$PROFILE_DIR" ]; then
      echo "Creating new LibreWolf profile for YouTube..."
      ${pkgs.librewolf}/bin/librewolf --headless --profile "$PROFILE_DIR" --createprofile default
    fi

    # Launch YouTube as standalone app
    exec ${pkgs.librewolf}/bin/librewolf --new-instance \
      --profile "$PROFILE_DIR" \
      --class "YouTubeApp" \
      --name "YouTubeApp" \
      --kiosk "https://www.youtube.com"
  '';

  desktopEntry = pkgs.makeDesktopItem {
    name = "youtube-app";
    exec = "youtube-app";
    icon = "librewolf";
    desktopName = "YouTube";
    genericName = "YouTube Desktop App";
    categories = [ "Network" "Video" ];
    startupWMClass = "YouTubeApp";
  };
in {
  environment.systemPackages = [
    youtube-app
    desktopEntry
    pkgs.librewolf  # Ensure LibreWolf is installed
  ];
} 
