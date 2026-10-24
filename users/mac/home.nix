{
  pkgs,
  inputs,
  config,
  lib,
  ...
}: {
  imports = [
    inputs.sops.homeManagerModules.sops

    ../../modules/home/claude-commit
    ../../modules/home/ssh
    ../../modules/home/eternal-terminal
    ../../modules/home/zsh
    ../../modules/home/alacritty
    ../../modules/home/kitty
    ../../modules/home/starship
    ../../modules/home/yt-dlp
    ../../modules/home/syncthing
    ../../modules/home/pgcli
    ../../modules/home/python
    # ../../modules/home/librewolf

    ../../modules/home-mac/aerospace
    ../../modules/home-mac/hermes-skins
    ../../modules/home-mac/winnie
    # ../../modules/home-mac/autossh
  ];

  home.username = "marc";
  home.homeDirectory = pkgs.lib.mkForce (
    if pkgs.stdenv.isDarwin
    then "/Users/marc"
    else "/home/marc"
  );
  home.stateVersion = "25.11";
  home.packages = with pkgs; [
    fzf
    gemini-cli
    geminicommit
    tree
    eza
    bat
    gnupg
    # claude-code
    # black
    ncdu
    nix-du
    util-linux
    sops
    typer
    nerd-fonts.meslo-lg # MesloLGS NF
    nmap
    just
    age
    speedtest-go
    gh
    uv

    # neovim deps manquants
    ripgrep # telescope live-grep + vim.health
    fd # telescope extended
    stylua # conform lua formatter
    prettier # conform prettier
    tree-sitter # lspsaga + nvim-treesitter CLI
    sox # gp.nvim audio
    pngpaste # img-clip (macOS)
    findutils # GNU find (fix fzf-lua "illegal option")
    luarocks # lazy.nvim rocks

    neovim-node-client # node provider

    # (nerdfonts.override { fonts = [ "Meslo" ]; })
    # ou sur nixpkgs récent :
    nerd-fonts.meslo-lg
    meslo-lg
    meslo-lgs-nf
    fastfetch
    htop
    nodejs

    upscayl
    upscayl-ncnn
    realesrgan-ncnn-vulkan
    imagemagick
    wireguard-tools
    iproute2mac
  ];

  # nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
  #   "claude-code"
  # ];

  home.sessionVariables = {
    SOPS_AGE_KEY_FILE = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  };

  # sops.age.keyFile = "/Users/marc/.config/sops/age/keys.txt";
  sops.age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/mac.yml;

  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-curses;
  };

  programs.home-manager = {
    enable = true;
    # backupFileExtension = "backup";
    # backupCommand',
  };

  programs.git = {
    enable = true;
    settings.user.name = "Marc Partensky";
    settings.user.email = "marc.partensky@gmail.com";
  };

  programs.zsh.enable = true;

  # Skins Hermes (pack Hermes Menagerie) -> ~/.hermes/skins/
  my.hermesSkins.enable = true;

  # Build de l'app Winnie sur le Mac : winnie-doctor, winnie-sync, winnie-ios,
  # winnie-macos, winnie-front, winnie-verify. Le toolchain reste dans le
  # devShell du flake `winnie`, ces commandes ne font que l'appeler.
  my.winnie.enable = true;

  # Connexions Eternal Terminal vers les hôtes NixOS : `et tower` = zellij enregistré.
  my.et = {
    enable = true;
    hosts = {
      tower = {};
      towerlocal = {};
    };
  };

  # Clé SSH de l'agent hermes@tower : l'agent (qui tourne sur tower) peut se
  # connecter au Mac en marc@… (sshd activé par services.openssh dans
  # profiles/macos/configuration.nix). Append idempotent plutôt que
  # home.file.".ssh/authorized_keys" : ne remplace JAMAIS un authorized_keys
  # déjà en place (le .bak de home-manager perdrait les clés existantes).
  home.activation.addHermesAuthorizedKey = lib.hm.dag.entryAfter ["writeBoundary"] ''
    key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower'
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    grep -qxF "$key" "$HOME/.ssh/authorized_keys" || echo "$key" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
  '';

  # Accès distant par rack (VPS à IP publique) : marche depuis n'importe quel
  # réseau, sans VPN sur le Mac. rack joint tower par le tunnel wg1
  # (10.100.0.3) et le LAN (192.168.1.0/24) que tower route pour wg1.
  # mkForce : ces deux entrées remplacent celles du module partagé.
  programs.ssh.settings = {
    "tower" = lib.mkForce {
      HostName = "10.100.0.3";
      User = "marc";
      ProxyJump = "rack";
    };
    "deck" = lib.mkForce {
      HostName = "192.168.1.67";
      User = "marc";
      ProxyJump = "rack";
    };
  };
}
