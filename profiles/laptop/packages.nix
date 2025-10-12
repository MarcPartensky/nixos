{ pkgs, inputs }:
let
  # Initialisation correcte de NUR
  nur = import inputs.nur {
    inherit pkgs;
    # Certains modules NUR nécessitent cela
    nurpkgs = pkgs; 
  };
  
  free = with pkgs; [
    inputs.agenix.packages.${pkgs.system}.default
    # inputs.nix-search-tv.packages.x86_64-linux.default
    nur.repos.nltch.spotify-adblock  # Accès corrigé
    # inputs.newt.packages.${pkgs.system}.default
    lxqt.lxqt-policykit
    nix-search-tv
    neovim
    wget
    p7zip
    git
    gitoxide
    gh
    codeberg-cli
    bluetuith
    alacritty
    kitty
    htop
    killall
    fzf
    firefox
    stow
    yarn
    gnumake
    just
    gparted
    lsof
    uv
    tree
    bat
    httpie
    dig
    firejail
    tealdeer
    acpi
    ripgrep
    speedtest
    speedtest-go
    ncdu
    nnn
    fastfetch
    arp-scan
    util-linux
    glances
    rbw
    rofi-rbw-wayland
    pinentry
    wl-clipboard
    gpt-cli
    open-webui
    nautilus
  ];
  
  unfree = with pkgs; [
    spotify
    steam
    steam-unwrapped
    # pkgs.nvidia-settings
    nvidia-vaapi-driver
    code-cursor
    claude-code
    morgen

  ];
in {
  all = free ++ unfree;
  inherit unfree;
}
