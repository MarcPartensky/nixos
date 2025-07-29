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
      ../../modules/kodi
      ../../modules/rbw
      ../../modules/mako
      ../../modules/radarr
      ../../modules/tealdeer
      ../../modules/polkit
      # ../../modules/tor-browser
      # ../../modules/sopswarden
      # ../../modules/greetd
      # ../../modules/kubernetes
    ];


  # home.file.".config/hypr/hyprland.conf".source = ../../modules/hyprland/hyprland.conf;

  # catppuccin.enable = true;
  # catppuccin.flavor = "macchiato";

  # environment.systemPackages = [
  #   (import inputs.newt { inherit (pkgs) system; }).packages.${pkgs.system}.default
  # ];

  home-manager = {
      backupFileExtension = "backup";
      extraSpecialArgs = { inherit inputs; };
      useGlobalPkgs = true;
      useUserPackages = true;
  };

  home-manager.users.marc = { pkgs, inputs, ... }: {
    # users.your-username = ./home.nix;  // Path to your HM config
    home.packages = with pkgs; [
      # cli
      # inputs.newt.packages.${pkgs.system}.default
      # inputs.pangolin-newt.packages.${pkgs.system}.default
      # pangolin-newt
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
      playerctl

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
      minitube
      freetube
      # gtk-pipe-viewer
      # onthespot
      # your_spotify
      wofi-power-menu
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

    programs.gpg.enable = true;
    services.gpg-agent = {
      enable = true;
      enableSshSupport = true;
    };
  
    # The state version is required and should stay at the version you
    # originally installed.
    home.stateVersion = "25.05";
  };

}
