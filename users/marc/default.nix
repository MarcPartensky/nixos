{ pkgs, home-manager, inputs, ... }:
{

  imports =
    [
      ../../modules/git
      ../../modules/hyprland
      ../../modules/waybar
      ../../modules/librewolf
      # ../../modules/firefox
      ../../modules/ssh
      ../../modules/virt-manager
      ../../modules/syncthing
      ../../modules/steam
      ../../modules/docker
      # ../../modules/podman
      ../../modules/zsh
      ../../modules/alacritty
      ../../modules/kodi
      ../../modules/rbw
      ../../modules/mako
      ../../modules/radarr
      ../../modules/tealdeer
      ../../modules/polkit
      ../../modules/thunderbird
      ../../modules/tor
      # ../../modules/microvm
      # ../../modules/chatgpt
      # ../../modules/tor-browser
      # ../../modules/sopswarden
      # ../../modules/greetd
      # ../../modules/kubernetes
    ];

  environment.variables = {
    NIX_DEV_SHELL_HOOK = ''zsh'';
  };

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
      wev
      # xev
      cliphist
      grim
      slurp
      swappy
      satty
      black
      isort
      python312Full
      python312Packages.pynvim
      gcc
      nodejs
      compose2nix

      # fosrl-newt
      # fosrl-olm


      # gui
      wasistlos
      # nextcloud-client
      jellyfin-web
      invidious
      tor-browser
      signal-desktop
      mpv
      wpaperd
      wofi
      rofi
      wdisplays
      wayvnc
      blueberry
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
      jellyfin
      libsForQt5.merkuro
      gcr_4
      glib-networking
      evolution-data-server
      xdg-desktop-portal-gnome
      gnome-online-accounts-gtk
      gnome-online-accounts
      versatiles
      gnome-maps
      protonmail-bridge
      pywalfox-native
      electrum
      sparrow
      wasabiwallet
      anki
      mnemosyne
      prismlauncher
      piper
      libratbag
      solaar
      teams-for-linux
    ];


    services.gnome-keyring = {
      enable = true;
      components = ["secrets" "ssh"];  # Explicitly enable secrets component
    };
    # programs.dconf.enable = true;
    # services.gnome-online-accounts.enable = true;

    # Start Evolution Data Server as user service
    systemd.user.services.evolution-data-server = {
      Unit = {
        Description = "Evolution Data Server";
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.evolution-data-server}/bin/evolution-data-server";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "default.target" ];
    };


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
