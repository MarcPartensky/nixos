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
      # ../../modules/kubernetes
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
      # ag
      nmap
      helm
      mako
      ripgrep
      spotdl
      wstunnel

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
      blueberry
      nautilus
      zathura
      element-desktop
      caprine
      goldwarden
      grim
      slurp
      swappy
      electron-mail
      grimblast
      nwg-dock-hyprland
      nwg-drawer
      obs-studio
    ];

    services.gammastep = {
      enable = true;
      provider = "manual";
      latitude = 48.0;
      longitude = 2.0;
    };

    systemd.user.services = {
      wpaperd = {
          Unit.Description = "wpaperd";
        Service = {
          Type = "exec";
          ExecStart = "${pkgs.wpaperd}/bin/wpaperd";
          Restart = "on-failure";
        };
        Install = { WantedBy = [ "default.target" ]; };
      };
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
