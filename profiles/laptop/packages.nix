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
    networkmanager

    # 🔹 Hardware / PCI / USB
    lshw
    pciutils      # pour lspci
    usbutils      # pour lsusb
    dmidecode
    inxi          # résumé complet du hardware
  
    # 🔹 GPU / drivers / OpenGL / VAAPI / Vulkan
    # mesa-utils    # glxinfo, glxgears
    vainfo        # VA-API (Intel/AMD video acceleration)
    vulkan-tools  # vulkaninfo
    intel-media-driver # si Intel GPU pour VA-API (optionnel)
    
    # 🔹 DRM / Wayland / GBM
    weston        # weston-info et test Wayland (optionnel)
    libgbm        # pour tester GBM devices
  
    # 🔹 Réseau
    networkmanager   # nmtui, nmcli
    wpa_supplicant   # si Wi-Fi managé par NM
    inetutils        # ping, traceroute, etc.
  
    # 🔹 Disques / partitionnement
    util-linux       # lsblk, blkid, fdisk
    gptfdisk         # gdisk
    parted            # parted pour partitions avancées
    smartmontools    # smartctl
  
    # 🔹 Debug / monitoring
    strace
    lsof
    htop
    perf
    valgrind         # optionnel pour debug mémoire

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
    # morgen
    beeper

  ];
in {
  all = free ++ unfree;
  inherit unfree;
}
