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
    # btop : theme Catppuccin Mocha (accent lavender) + vue CPU par process.
    # htop (plus bas, xdg.configFile) herite du palette ANSI de kitty ; btop
    # est le seul a lire un vrai fichier de theme 24 bits.
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
    # Sessions hermes lancees par marc (panes herdr) : partager l'etat du
    # service au lieu de /home/marc/.hermes. C'est ce qui rend l'integration
    # herdr utilisable : hermes tourne alors sous marc, meme utilisateur que le
    # serveur herdr, donc HERDR_ENV/HERDR_PANE_ID survivent et le socket
    # ~/.config/herdr/herdr.sock est accessible.
    # Acces au state dir : groupe hermes (users.nix) + ACL declarees dans
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

  # Connexions Eternal Terminal : `et <hôte>` = zellij + enregistrement asciinema
  # (fonctions ettower / ettowerlocal / ets générées, cf. modules/home/eternal-terminal)
  my.et = {
    enable = true;
    hosts = {
      tower = { };
      towerlocal = { };
    };
  };

  # zellij partout : tout shell interactif (ssh compris) se rattache a une
  # session, donc une coupure detache au lieu de tuer le travail en cours.
  # Les shells non interactifs (ssh hote 'commande', scripts, l'agent) ne sont
  # pas concernes ; echappatoire : `ssh -t hote 'ZELLIJ=0 bash -l'`.
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

  # .gtkrc-2.0 est généré par gtk.enable ; l'ancien fichier n'est pas un lien
  # vers le store, donc sans force = true l'activation échoue sur checkLinkTargets.
  home.file.${config.gtk.gtk2.configLocation}.force = lib.mkForce true;
  xdg.configFile = {
    "gtk-3.0/settings.ini".force = true;
    "gtk-4.0/settings.ini".force = true;
    "gtk-4.0/gtk.css".force = true;
    # Colonnes et ecrans htop, au plus pres de glances : bandeau de jauges
    # (CPU + par thread, MEM, SWP, reseau, disque, load, taches, uptime, heure)
    # puis table des process facon glances (CPU%, MEM%, VIRT, RES, PID, USER,
    # NI, S, TIME+, Command). Meme fichier que le defaut systeme /etc/htoprc,
    # pour ne pas dependre du fait d'avoir ou non un htoprc personnel.
    # force = true remplace un htoprc edite a la main ; le lien pointe dans le
    # store, donc htop ne peut plus y ecrire : passer par ce fichier.
    "htop/htoprc" = {
      source = ../../modules/nixos/htop/htoprc;
      force = true;
    };
  };

  programs.home-manager.enable = true;

  home.stateVersion = "25.11";
}
