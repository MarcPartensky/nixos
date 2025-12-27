{ inputs, pkgs, home-manager, lib, ... }:

let
  home = "/home/marc";
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
    # glib
    # gsettings-desktop-schemas
    udiskie
    nix-du
    wireguard-tools
    moodle-dl
    power-profiles-daemon
    upower
    libgtop
    bitwarden-cli
    wl-clipboard-rs
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
    yazi
    virt-manager
    flatpak
    gnome-software # for flatpak
    # spotify
    pkgs.nur.repos.nltch.spotify-adblock
    code-cursor
    claude-code
    nautilus
    beeper
    firefox
    helvum
    # inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
in
{
  imports = [
    ../../modules/home/git
    # ../../modules/home/hyprland
    ../../modules/home/niri
    ../../modules/home/zsh
    ../../modules/home/alacritty
    ../../modules/home/wallpapers
    ../../modules/home/syncthing
    ../../modules/home/ssh
    ../../modules/home/tealdeer
    ../../modules/home/neovim
    ../../modules/home/gh
    ../../modules/home/gtk
    ../../modules/home/xdg
    ../../modules/home/satty
    ../../modules/home/pgcli
    ../../modules/home/gpg
    ../../modules/home/wofi
    ../../modules/home/dconf
    ../../modules/home/waybar # (incompatible hyprpanel)
    ../../modules/home/mako # (incompatible hyprpanel)
    # ../../modules/home/hyprpanel
    ../../modules/home/gammastep
    ../../modules/home/udiskie
    ../../modules/home/starship
    ../../modules/home/kodi
    ../../modules/home/topgrade
    ../../modules/home/rbw
    ../../modules/home/mpv
    ../../modules/home/eww
    ../../modules/home/zen-browser
    # ../../modules/home/sopswarden
    # ../../modules/home/polkit
    # ../../modules/home/ipython
    # ../../modules/home/librewolf
    # ../../modules/home/steam
    # ../../modules/home/docker
    # ../../modules/home/thunderbird
    # ../../modules/home/tor
  ];

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "spotify"
    "cursor"
    "claude-code"
    "beeper"
  ];

  home.sessionVariables = {
    GSETTINGS_SCHEMA_DIR =
      "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}";
    DBUS_SESSION_BUS_ADDRESS = "${builtins.getEnv "DBUS_SESSION_BUS_ADDRESS"}";
    SAL_USE_VCLPLUGIN = "gen";

    DEFAULT_BROWSER =
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;
    BROWSER =
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;

    # XDG_DATA_HOME      = "${home}/.local/share";
    # XDG_CONFIG_HOME    = "${home}/.config";
    # XDG_CACHE_HOME     = "${home}/.cache";
    # # XDG_RUNTIME_DIR    = "/run/user/${toString config.home.uid}";
    # XDG_DATA_DIRS = ''
    #   /var/lib/flatpak/exports/share
    #   ${home}/.local/share/flatpak/exports/share
    #   ${home}/.local/state/nix/profile/share
    #   ${home}/.nix-profile/share
    #   /nix/profile/share
    #   /etc/profiles/per-user/marc/share
    #   /nix/var/nix/profiles/default/share
    #   /run/current-system/sw/share
    # '';
    # XDG_CONFIG_DIRS    = "/etc/xdg";
    # PATH = "${home}/.local/bin:$PATH";
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = [ "zen.desktop" ];
      "x-scheme-handler/http" = [ "zen.desktop" ];
      "x-scheme-handler/https" = [ "zen.desktop" ];
      "x-scheme-handler/about" = [ "zen.desktop" ];
      "x-scheme-handler/unknown" = [ "zen.desktop" ];
    };
  };

  xdg.enable = true;
  xdg.systemDirs.data = [
    "/var/lib/flatpak/exports/share"
    "/home/marc/.local/share/flatpak/exports/share"
    "/run/current-system/sw/share"
    "/nix/var/nix/profiles/default/share"
    "/etc/profiles/per-user/marc/share"
    "/home/marc/.local/state/nix/profile/share"
    "/nix/profile/share"
    "/home/marc/.nix-profile/share"
  ];




  home = {
    username = "marc";
    homeDirectory = "/home/marc";
  	packages = cliPackages ++ guiPackages ++ [ pythonEnv ];
  };

  # environment.variables = {
  #   NIX_DEV_SHELL_HOOK = "zsh";
  # };

	# home.backupFileExtension = "backup";

  # nixpkgs.config.permittedInsecurePackages = [
  #   "electron-36.9.5" # Autorise ce paquet spécifique
  # ];

  # xdg.userDirs = {
  #   enable = true;
  #   download = "${config.home.homeDirectory}/downloads";
  # };

  services.gnome-keyring = {
    enable = true;
    components = ["secrets" "ssh"];
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

  home.stateVersion = "25.11";
}

