{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    # ./modules/sshd
    # ../../nod-sshd
    # ../../zsh
    # ../../services/postgres
    # ../../services/nextcloud
    # ../../services/radarr
  ];

  # Simply install just the packages
  environment.packages = with pkgs; [
    # Some common stuff that people expect to have
    procps
    killall
    fastfetch
    #diffutils
    #findutils
    #utillinux
    #tzdata
    #hostname
    #man
    #gnugrep
    #gnupg
    #gnused
    #gnutar
    #bzip2
    #gzip
    #xz
    #zip
    #unzip
    nano
    openssh
    iproute2
    shadow
    neovim
    zsh
    git
    gh
    just
    wayvnc
    stow
    ncdu
    # pangolin
    htop
    which
    podman
    neofetch
    # gemini-cli-bin
    tmate
    bat
    ripgrep

    pinentry-curses
  ];

  home-manager.config = {
    home.stateVersion = "24.05";
    imports = [
      inputs.nixvim.homeManagerModules.default
      # ../../modules/home/yt-dlp
      ../../modules/home/neovim
      # ../../modules/home/zsh
      # ../../modules/home/git
      # ../../modules/home/ssh
      # ../../modules/home/gh
    ];
  };

  user.shell = "${pkgs.zsh}/bin/zsh";

  # --- CONFIGURATION GPG (OBLIGATOIRE SUR 25.11) ---
  # Sans ça, git sign / gpg plantera car il ne trouvera pas pinentry
  environment.etc."gnupg/gpg-agent.conf".text = ''
    pinentry-program ${pkgs.pinentry-curses}/bin/pinentry
  '';

  # Ces options activent l'intégration Home Manager
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-backup";

  # environment.pathsToLink = [
  #   "/share/applications"
  #   "/share/xdg-desktop-portal"
  # ];

  # Backup etc files instead of failing to activate generation if a file already exists in /etc
  environment.etcBackupExtension = ".bak";

  # Read the changelog before changing this value
  system.stateVersion = "24.05";

  # Set up nix for flakes
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # Set your time zone
  time.timeZone = "Europe/Paris";
}
