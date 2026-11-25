{
  inputs,
  pkgs,
  lib,
  config,
  ...
}: {
  imports = [
    ./packages.nix

    inputs.catppuccin.homeModules.catppuccin
    inputs.nixvim.homeModules.default
    inputs.sops.homeManagerModules.sops
    inputs.sopswarden.homeManagerModules.default
    inputs.niri.homeModules.niri
    inputs.nix-flatpak.homeManagerModules.nix-flatpak
    inputs.spicetify.homeManagerModules.spicetify

    # inputs.backtest.packages.${pkgs.system}.default
    # inputs.option-pricer.packages.${pkgs.system}.default

    ../../modules/home/git
    ../../modules/home/zsh
    ../../modules/home/ssh
    ../../modules/home/eternal-terminal
    ../../modules/home/zellij
    ../../modules/home/tealdeer
    ../../modules/home/neovim
    ../../modules/home/gh
    ../../modules/home/starship
    ../../modules/home/topgrade
    ../../modules/home/rbw
    ../../modules/home/yt-dlp
    ../../modules/home/claude-commit
    ../../modules/home/niri
    ../../modules/home/wayvnc
    ../../modules/home/alacritty
    ../../modules/home/kitty
    # btop: Catppuccin Mocha theme (lavender accent) + CPU view per process.
    # htop (below, xdg.configFile) inherits kitty's ANSI palette; btop
    # is the only one to read a real 24-bit theme file.
    ../../modules/home/btop
    ../../modules/home/wallpapers
    ../../modules/home/syncthing
    ../../modules/home/gtk
    ../../modules/home/xdg
    ../../modules/home/satty
    ../../modules/home/pgcli
    ../../modules/home/gpg
    ../../modules/home/wofi
    ../../modules/home/dconf
    ../../modules/home/ironbar
    ../../modules/home/mako
    ../../modules/home/gammastep
    ../../modules/home/udiskie
    ../../modules/home/kodi
    ../../modules/home/mpv
    ../../modules/home/zen-browser
    ../../modules/home/tor-browser
    # ../../modules/home/nxbt
    ../../modules/home/batsignal
    ../../modules/home/playsched
    ../../modules/home/zathura
    ../../modules/home/spicetify
    ../../modules/home/watt-monitor
    ../../modules/home/deepfilter
    ../../modules/home/tewi
    ../../modules/home/ytui-music
    ../../modules/home/ytm-player
    ../../modules/home/yututui
    ../../modules/home/yt-collate
    ../../modules/home/youtube-music-cli
    ../../modules/home/geminicommit

    ../../modules/home/backtest
    ../../modules/home/portfolio-optimizer
    ../../modules/home/option-pricer
  ];

  nixpkgs.config.electron.commandLineArgs =
    "--ozone-platform-hint=auto "
    + "--ozone-platform=wayland "
    + "--disable-gpu-sandbox "
    + "--no-sandbox "
    + "--enable-features=WaylandWindowDecorations";

  sops.age.keyFile = "/home/marc/.config/sops/age/keys.txt";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;

  home = {
    username = "marc";
    homeDirectory = "/home/marc";
  };

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    # hermes sessions launched by marc (herdr panes): share the service
    # state instead of /home/marc/.hermes. This is what makes the herdr
    # integration usable: hermes then runs under marc, the same user as the
    # herdr server, so HERDR_ENV/HERDR_PANE_ID survive and the socket
    # ~/.config/herdr/herdr.sock is accessible.
    # Access to the state dir: hermes group (users.nix) + ACLs declared in
    # profiles/tower/configuration.nix.
    HERMES_HOME = "/var/lib/hermes/.hermes";
    GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}";
    DEFAULT_BROWSER = "${inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/zen";
    BROWSER = "${inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/zen";
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    NIXOS_OZONE_WL = "1";
    GTK_USE_PORTAL = "1";
    GDK_BACKEND = "wayland";
    XDG_SESSION_TYPE = "wayland";
    QT_QPA_PLATFORM = "wayland";
  };

  xdg.enable = true;
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = ["zen.desktop"];
      "x-scheme-handler/http" = ["zen.desktop"];
      "x-scheme-handler/https" = ["zen.desktop"];
      "x-scheme-handler/about" = ["zen.desktop"];
      "x-scheme-handler/unknown" = ["zen.desktop"];
      "video/mp4" = ["mpv.desktop"];
    };
  };

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

  services.darkman = {
    enable = true;
    settings = {
      lat = 48.8;
      lng = 2.3;
    };
  };

  services.gnome-keyring = {
    enable = true;
    components = ["secrets" "ssh"];
  };

  # Eternal Terminal connections: `et <host>` = zellij + asciinema recording
  # (functions ettower / ettowerlocal / ets generated, cf. modules/home/eternal-terminal)
  my.et = {
    enable = true;
    hosts = {
      tower = { };
      towerlocal = { };
    };
  };

  # zellij everywhere: every interactive shell (ssh included) attaches to a
  # session, so a drop detaches instead of killing the work in progress.
  # Non-interactive shells (ssh host 'command', scripts, the agent) are not
  # affected; escape hatch: `ssh -t host 'ZELLIJ=0 bash -l'`.
  my.zellij.autostart = true;

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  home.file."Desktop/return-to-gaming-mode.desktop" = {
    executable = true;
    text = ''
      [Desktop Entry]
      Name=Return to Gaming Mode
      Exec=steamos-session-select gamescope
      Icon=steam
      Terminal=false
      Type=Application
    '';
  };

  # .gtkrc-2.0 is generated by gtk.enable; the old file is not a link
  # to the store, so without force = true activation fails on checkLinkTargets.
  home.file.${config.gtk.gtk2.configLocation}.force = lib.mkForce true;
  xdg.configFile = {
    "gtk-3.0/settings.ini".force = true;
    "gtk-4.0/settings.ini".force = true;
    "gtk-4.0/gtk.css".force = true;
    # htop columns and screens, as close as possible to glances: a row of gauges
    # (CPU + per thread, MEM, SWP, network, disk, load, tasks, uptime, time)
    # then a glances-style process table (CPU%, MEM%, VIRT, RES, PID, USER,
    # NI, S, TIME+, Command). Same file as the system default /etc/htoprc,
    # to avoid depending on whether a personal htoprc exists.
    # force = true replaces a hand-edited htoprc; the link points into the
    # store, so htop can no longer write to it: go through this file.
    "htop/htoprc" = {
      source = ../../modules/nixos/htop/htoprc;
      force = true;
    };
  };

  programs.home-manager.enable = true;

  home.stateVersion = "25.11";
}
