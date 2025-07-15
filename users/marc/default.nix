{ pkgs, home-manager, inputs, ... }:
{

  imports =
    [
      ../../modules/git
      ../../modules/hyprland
      ../../modules/waybar
      ../../modules/librewolf
      ../../modules/ssh
      ../../modules/virt-manager
      ../../modules/syncthing
      ../../modules/steam
      ../../modules/docker
      ../../modules/zsh
      ../../modules/alacritty
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
      talosctl
      realesrgan-ncnn-vulkan
      realcugan-ncnn-vulkan
      compose2nix
      vtracer
      tmux
      tmate
      firefoxpwa
      chatgpt-cli
      lowfi
      ytmdl

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
      qbittorrent
      nuclear
      novnc
      libreoffice
      geary
      ytmdesktop
      ytui-music
      # waybar-hyprland
      whitesur-gtk-theme
      webcord
      pipe-viewer
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

    programs.gpg.enable = true;
    services.gpg-agent = {
      enable = true;
      enableSshSupport = true;
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
