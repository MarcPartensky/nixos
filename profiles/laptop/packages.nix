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
  ];
  
  unfree = [
    pkgs.spotify
    pkgs.steam
    pkgs.steam-unwrapped
    # pkgs.nvidia-settings
    pkgs.nvidia-vaapi-driver
  ];
in {
  all = free ++ unfree;
  inherit unfree;
}
