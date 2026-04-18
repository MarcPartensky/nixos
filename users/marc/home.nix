{
  inputs,
  pkgs,
  lib,
  config,
  ...
}: let
  isLinux = builtins.match ".*-linux" builtins.currentSystem != null;
  isDarwin = builtins.match ".*-darwin" builtins.currentSystem != null;
  homeDir = if isDarwin then "/Users/marc" else "/home/marc";
in {
  imports = [
    ./packages.nix

    inputs.catppuccin.homeModules.catppuccin
    inputs.nixvim.homeModules.default
    inputs.sops.homeManagerModules.sops

    ../../modules/home/git
    ../../modules/home/zsh
    ../../modules/home/ssh
    ../../modules/home/tealdeer
    ../../modules/home/neovim
    ../../modules/home/gh
    ../../modules/home/starship
    ../../modules/home/topgrade
    ../../modules/home/rbw
    ../../modules/home/yt-dlp
    ../../modules/home/claude-commit
  ] ++ lib.optionals isLinux [
    inputs.sopswarden.homeManagerModules.default
    inputs.niri.homeModules.niri
    inputs.nix-flatpak.homeManagerModules.nix-flatpak
    inputs.spicetify.homeManagerModules.spicetify

    ../../modules/home/niri
    ../../modules/home/alacritty
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
    ../../modules/home/nxbt
    ../../modules/home/batsignal
    ../../modules/home/playsched
    ../../modules/home/zathura
    ../../modules/home/spicetify
    ../../modules/home/watt-monitor
    ../../modules/home/deepfilter
    ../../modules/home/tewi
    ../../modules/home/ytui-music
  ];

  nixpkgs.config.electron.commandLineArgs = lib.mkIf isLinux (
    "--ozone-platform-hint=auto "
    + "--ozone-platform=wayland "
    + "--disable-gpu-sandbox "
    + "--no-sandbox "
    + "--enable-features=WaylandWindowDecorations"
  );

  sops.age.keyFile = "${homeDir}/.config/sops/age/keys.txt";

  home = {
    username = "marc";
    homeDirectory = homeDir;
  };

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  } // lib.optionalAttrs isLinux {
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
  xdg.mimeApps = lib.mkIf isLinux {
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

  xdg.systemDirs.data = lib.mkIf isLinux [
    "/var/lib/flatpak/exports/share"
    "/home/marc/.local/share/flatpak/exports/share"
    "/run/current-system/sw/share"
    "/nix/var/nix/profiles/default/share"
    "/etc/profiles/per-user/marc/share"
    "/home/marc/.local/state/nix/profile/share"
    "/nix/profile/share"
    "/home/marc/.nix-profile/share"
  ];

  services.darkman = lib.mkIf isLinux {
    enable = true;
    settings = { lat = 48.8; lng = 2.3; };
  };

  services.gnome-keyring = lib.mkIf isLinux {
    enable = true;
    components = ["secrets" "ssh"];
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  programs.home-manager.enable = true;

  home.stateVersion = "25.11";
}
