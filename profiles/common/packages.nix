{
  pkgs,
  inputs,
}: let
  # thClaws : paquet du flake projet /home/marc/git/thclaws, copie dans
  # services/thclaws/package.nix parce que l'eval NixOS est PURE (skill
  # nixos-pure-eval) : un `callPackage /home/marc/git/...` est un chemin absolu
  # hors depot, refuse en eval pure. Le flake projet reste utilisable seul
  # (nix build .#) ; les deux copies portent la meme version et le meme sha256.
  thclaws = pkgs.callPackage ../../services/thclaws/package.nix { };

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
    # zellij en profil systeme : l'agent (hermes) et root peuvent s'y rattacher
    # sur n'importe quel hote, pas seulement dans le home-manager de marc.
    zellij
    # ttyper : entrainement a la frappe au toucher en terminal (Rust/ratatui).
    # Version TUI de typer.macpartensky.com, meme listes de mots. En profil
    # systeme pour etre utilisable tout de suite par marc ET par l'agent.
    ttyper
  ] ++ [ thclaws ];

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
