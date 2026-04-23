{
  pkgs,
  inputs,
}: let
  # Initialisation correcte de NUR
  nur = import inputs.nur {
    inherit pkgs;
    # Certains modules NUR nécessitent cela
    nurpkgs = pkgs;
  };

  free = with pkgs; [
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
    home-manager
    # inputs.nix-search-tv.packages.x86_64-linux.default
    # nur.repos.nltch.spotify-adblock # spotify-1.2.59.514.g834e17d4.drv' failed with exit code 11;
    # inputs.newt.packages.${pkgs.system}.default
    lxqt.lxqt-policykit
    nix-search-tv
    networkmanager

    # 🔹 Hardware / PCI / USB
    lshw
    pciutils # pour lspci
    usbutils # pour lsusb
    dmidecode
    inxi # résumé complet du hardware

    # 🔹 GPU / drivers / OpenGL / VAAPI / Vulkan
    # mesa-utils    # glxinfo, glxgears
    # vainfo        # VA-API (Intel/AMD video acceleration)
    vulkan-tools # vulkaninfo
    intel-media-driver # si Intel GPU pour VA-API (optionnel)

    # 🔹 DRM / Wayland / GBM
    weston # weston-info et test Wayland (optionnel)
    libgbm # pour tester GBM devices

    # 🔹 Réseau
    networkmanager # nmtui, nmcli
    wpa_supplicant # si Wi-Fi managé par NM
    inetutils # ping, traceroute, etc.

    # 🔹 Disques / partitionnement
    util-linux # lsblk, blkid, fdisk
    gptfdisk # gdisk
    parted # parted pour partitions avancées
    smartmontools # smartctl

    # 🔹 Debug / monitoring
    strace
    lsof
    htop
    # perf
    valgrind # optionnel pour debug mémoire

    neovim
    wget
    p7zip
    git
    gh
    codeberg-cli
    bluetuith
    bluetui
    kitty
    alacritty
    fuzzel
    htop
    killall
    fzf
    stow
    yarn
    gnumake
    just
    gparted
    lsof
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
    # pinentry
    less
    yq
    eza
    gsettings-desktop-schemas
    glib
    exfatprogs
  ];

  unfree = with pkgs; [
    steam
    steam-unwrapped
    # pkgs.nvidia-settings
    nvidia-vaapi-driver
    # morgen
  ];
in {
  all = free ++ unfree;
  inherit unfree;
}
