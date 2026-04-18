{
  pkgs,
  lib,
  inputs,
  ...
}: let
  isLinux = builtins.match ".*-linux" builtins.currentSystem != null;
  isDarwin = builtins.match ".*-darwin" builtins.currentSystem != null;

  pythonEnv =
    (pkgs.python313.override {
      packageOverrides = self: super: {
        weasel = super.weasel.overridePythonAttrs (old: {
          dontCheckRuntimeDeps = true;
        });
      };
    }).withPackages (ps:
      with ps; [
        numpy
        pandas
        matplotlib
        scipy
        scikit-learn
        ipython
        requests
        pillow
      ] ++ lib.optionals isLinux [
        playwright
        jupyterlab
        edge-tts
      ]);

  commonPackages = with pkgs; [
    bat
    eza
    btop
    ripgrep
    fd
    jq
    tmux
    zellij
    uv
    nmap
    pandoc
    ffmpeg
    imagemagick
    alejandra
    stylua
    yamlfmt
    opentofu
    tree-sitter
    unzip
    cmake
    nodejs
    black
    isort
    gcc
    yt-dlp
    spotdl
    bitwarden-cli
    typer
    yazi
    eternal-terminal
    anki
    libreoffice-fresh
  ];

  linuxPackages = with pkgs; [
    pw-volume
    brightnessctl
    pwvucontrol
    wl-clipboard-rs
    wev
    cliphist
    playerctl
    mako
    udiskie
    glib
    dconf
    libgtop
    libGL
    wireguard-tools
    power-profiles-daemon
    upower
    tlp
    nix-du
    disko
    steam-run
    compose2nix
    helm
    talosctl
    nerdctl
    tmate
    wstunnel
    moodle-dl
    librespeed-cli
    openai-whisper
    gemini-cli
    gemini-cli-bin
    geminicommit
    img2pdf
    poppler-utils
    ffmpegthumbnailer
    texlive.combined.scheme-small
    pandoc-katex
    gurk-rs
    chatgpt-cli
    lowfi
    ytmdl
    ytermusic
    ytui-music
    libsecret
    gnome-online-accounts
    evolution-data-server
    gcr
    libgdata
    gnome-control-center
    firefoxpwa
    mpv
    wpaperd
    wofi
    rofi
    wdisplays
    wayvnc
    blueberry
    grim
    slurp
    swappy
    satty
    electron-mail
    grimblast
    nwg-dock-hyprland
    nwg-drawer
    obs-studio
    nuclear
    novnc
    geary
    ytmdesktop
    pipe-viewer
    minitube
    freetube
    wofi-power-menu
    jellyfin
    gcr_4
    glib-networking
    xdg-desktop-portal-gnome
    gnome-online-accounts-gtk
    versatiles
    gnome-maps
    protonmail-bridge
    pywalfox-native
    wasabiwallet
    mnemosyne
    libheif
    virt-manager
    flatpak
    gnome-software
    code-cursor
    claude-code
    nautilus
    beeper
    firefox
    helvum
    gtk3
    gtk4
    onionshare
    harmonoid
    feishin
    beekeeper-studio
    dbgate
    antares
    pgweb
    zettlr
    pdfarranger
    rqbit
    memorado
    logseq
    joplin-desktop
    ncspot
    spotify-player
    invidious
    discord
    signal-desktop
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
    prismlauncher
    ventoy-full
    zenity
    mesa-demos
    vulkan-tools
    jre
    playwright
  ];

  darwinPackages = with pkgs; [];
in {
  home.packages =
    commonPackages
    ++ [pythonEnv]
    ++ lib.optionals isLinux linuxPackages
    ++ lib.optionals isDarwin darwinPackages;

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) (
      ["claude-code"]
      ++ lib.optionals isLinux [
        "spotify"
        "cursor"
        "beeper"
        "harmonoid"
        "steam-run"
        "steam-unwrapped"
        "ventoy-gtk3"
        "ventoy"
        "discord"
      ]
    );

  nixpkgs.config.permittedInsecurePackages = lib.optionals isLinux [
    "beekeeper-studio-5.3.4"
    "libsoup-2.74.3"
    "ventoy-gtk3-1.1.10"
    "ventoy-1.1.10"
  ];
}
