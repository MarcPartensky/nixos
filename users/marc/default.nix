{ pkgs, home-manager, inputs, ... }:
{

  imports =
    [
      ../../modules/git
      ../../modules/hyprland
      ../../modules/librewolf
      ../../modules/ssh
      ../../modules/virt-manager
      ../../modules/syncthing
    ];

  # home.file.".config/hypr/hyprland.conf".source = ../../modules/hyprland/hyprland.conf;

  home-manager.backupFileExtension = "backup";

  home-manager.users.marc = { pkgs, inputs, ... }: {
    home.packages = with pkgs; [
      # cli
      bat
      tmate
      typer
      yt-dlp
      uv
      pw-volume
      wl-clipboard-rs
      brightnessctl
      librespeed-cli
      pwvucontrol
      sonusmix
      btop

      # gui
      wasistlos
      nextcloud-client
      jellyfin-web
      invidious
      tor-browser
      signal-desktop
      kodi
      mpv
      wpaperd
      wofi
      rofi
      wdisplays
      wayvnc
      ripgrep
      blueberry
      nautilus
      # ag
    ];

    services.gammastep = {
      enable = true;
      provider = "manual";
      latitude = 48.0;
      longitude = 2.0;
    };

  #   services.wpaperd = {
  #     enable = true;
  #     settings = {
  #       default = {
  #         path = "/home/marc/wallpapers";
  #         duration = "30m";
  #         apply-shadow = true;
  #         sorting = "random";
  #       };
  # 
  #     };
  #   };

  
    # The state version is required and should stay at the version you
    # originally installed.
    home.stateVersion = "25.05";
  };

}
