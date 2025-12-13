{ pkgs, home-manager, inputs, ... }:

let
  # -------------------------------
  # CLI Packages
  # -------------------------------
  pythonEnv = pkgs.python313.withPackages (ps: with ps; [
    numpy
    pandas
    matplotlib
    scipy
    scikit-learn
    jupyterlab
    ipython
    requests
    pillow
  ]);
  cliPackages = with pkgs; [
    bat
    tmate
    typer
    yt-dlp
    ytmdl
    spotdl
    uv
    pw-volume
    brightnessctl
    librespeed-cli
    pwvucontrol
    # sonusmix
    btop
    nmap
    helm
    mako
    ripgrep
    wstunnel
    talosctl
    black
    isort
    gcc
    nodejs
    tmux
    compose2nix
    gurk-rs
    chatgpt-cli
    lowfi
    wev
    cliphist
    nerdctl
    # crictl
    dconf
    playerctl
    nushell
  ];

  # -------------------------------
  # GUI Packages
  # -------------------------------
  guiPackages = with pkgs; [
    firefoxpwa
    mpv
    wpaperd
    wofi
    rofi
    wdisplays
    wayvnc
    blueberry
    # caprine
    # goldwarden
    grim
    slurp
    swappy
    satty
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
    # whitesur-gtk-theme
    # webcord # ‘electron-36.9.5’ to `permittedInsecurePackages`
    pipe-viewer
    minitube
    freetube
    wofi-power-menu
    jellyfin
    # libsForQt5.merkuro
    gcr_4
    glib-networking
    # evolution-data-server
    xdg-desktop-portal-gnome
    gnome-online-accounts-gtk
    gnome-online-accounts
    versatiles
    gnome-maps
    protonmail-bridge
    pywalfox-native
    # electrum # ‘python3.12-ecdsa-0.19.1’ to `permittedInsecurePackages`
    # sparrow # ‘python3.12-ecdsa-0.19.1’ to `permittedInsecurePackages`
    wasabiwallet
    anki
    mnemosyne
    libGL
    prismlauncher
    piper
    libratbag
    solaar
    teams-for-linux
    wireguard-ui
    wg-netmanager
    openvpn
    openvpn3
    protonvpn-gui
    tor-browser
    ungoogled-chromium
    netsurf-browser
    bitwarden-desktop
    feh
    libheif
  ];
in
{
  imports = [
    ../../modules/git
    ../../modules/hyprland
    ../../modules/waybar
    ../../modules/zsh
    ../../modules/alacritty
    ../../modules/wallpapers
    ../../modules/mako
    ../../modules/syncthing
    ../../modules/ssh
    ../../modules/tealdeer
    ../../modules/neovim
    ../../modules/gh
    ../../modules/gtk
    ../../modules/xdg
    ../../modules/satty
    # ../../modules/polkit
    # ../../modules/ipython
    # ../../modules/librewolf
    # ../../modules/virt-manager
    # ../../modules/steam
    # ../../modules/docker
    # ../../modules/kodi
    # ../../modules/rbw
    # ../../modules/radarr
    # ../../modules/thunderbird
    # ../../modules/tor
  ];

  home = {
    username = "marc";
    homeDirectory = "/home/marc";
  };

  # environment.variables = {
  #   NIX_DEV_SHELL_HOOK = "zsh";
  # };

  home.packages = cliPackages ++ guiPackages ++ [ pythonEnv ];
  # programs.delta.enable = true;

  # nixpkgs.config.permittedInsecurePackages = [
  #   "electron-36.9.5" # Autorise ce paquet spécifique
  # ];

  # xdg.userDirs = {
  #   enable = true;
  #   download = "${config.home.homeDirectory}/downloads";
  # };


  # services.librespot.enable = true;

  services.gnome-keyring = {
    enable = true;
    components = ["secrets" "ssh"];
  };

  programs.pgcli.enable = true;
  programs.topgrade.enable = true;

  # Configuration DConf pour Nautilus
  dconf.settings = {
    "org/gnome/nautilus/preferences" = {
      default-folder-viewer = "'list-view'";
    };
    "org/gnome/nautilus/list-view" = {
      sort-column = "'modified'";
      sort-order  = "'descending'";
    };
  };

  # programs.dconf.enable = true;

  programs.gpg.enable = true;
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
  };

  # systemd.user.services = {
  #   evolution-data-server = {
  #     Unit.Description = "Evolution Data Server";
  #     Unit.After = ["graphical-session.target"];
  #     Service.ExecStart = "${pkgs.evolution-data-server}/bin/evolution-data-server";
  #     Service.Restart = "on-failure";
  #     Install.WantedBy = ["default.target"];
  #   };
  # };

  services.gammastep = {
    enable = true;
    provider = "manual";
    latitude = 48.0;
    longitude = 2.0;
  };

  home.stateVersion = "25.05";
}

