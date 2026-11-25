{
  pkgs,
  inputs,
}: let
  # thClaws: package of the project flake /home/marc/git/thclaws, copied into
  # services/thclaws/package.nix because the NixOS eval is PURE (skill
  # nixos-pure-eval): a `callPackage /home/marc/git/...` is an absolute path
  # outside the repo, refused in pure eval. The project flake remains usable alone
  # (nix build .#); both copies carry the same version and the same sha256.
  thclaws = pkgs.callPackage ../../services/thclaws/package.nix { };

  # Correct initialization of NUR
  nur = import inputs.nur {
    inherit pkgs;
    # Some NUR modules require this
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
    pciutils # for lspci
    usbutils # for lsusb
    dmidecode
    inxi # full hardware summary

    # 🔹 GPU / drivers / OpenGL / VAAPI / Vulkan
    # mesa-utils    # glxinfo, glxgears
    # vainfo        # VA-API (Intel/AMD video acceleration)
    vulkan-tools # vulkaninfo
    intel-media-driver # if Intel GPU for VA-API (optional)

    # 🔹 DRM / Wayland / GBM
    weston # weston-info and Wayland test (optional)
    libgbm # to test GBM devices

    # 🔹 Network
    networkmanager # nmtui, nmcli
    wpa_supplicant # if Wi-Fi managed by NM
    inetutils # ping, traceroute, etc.

    # 🔹 Disks / partitioning
    util-linux # lsblk, blkid, fdisk
    gptfdisk # gdisk
    parted # parted for advanced partitions
    smartmontools # smartctl

    # 🔹 Debug / monitoring
    strace
    lsof
    htop
    # perf
    valgrind # optional for memory debug

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
    # zellij in the system profile: the agent (hermes) and root can attach to it
    # on any host, not only in marc's home-manager.
    zellij
    # ttyper: touch-typing practice in the terminal (Rust/ratatui).
    # TUI version of typer.macpartensky.com, same word lists. In the system
    # profile so it is usable right away by marc AND by the agent.
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
