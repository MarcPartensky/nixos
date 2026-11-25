{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hermes-access.nix
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
    eza
    nano
    openssh
    curl # re-run of the bootstrap via short link (curl -fsSL https://x.gd/a6gpx | sh)
    iproute2
    shadow
    neovim
    zsh
    git
    # gh
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
    tmux # session visible to marc: the agent types into `tmux -s hermes`, it attaches
    bat
    ripgrep
    qemu

    # pinentry-curses
  ];

  # home-manager.users.nix-on-droid = {
  #   home.stateVersion = "25.11";
  #   imports = [
  #     inputs.nixvim.homeModules.default
  #     ../../modules/home/neovim
  #     ../../modules/home/zsh
  #     ../../modules/home/git
  #     ../../modules/home/ssh
  #     # ../../modules/home/gh
  #   ];
  # };

  home-manager.config = {
    home.stateVersion = "24.05";
    # home.packages = [
    #   (inputs.nixvim.legacyPackages.aarch64-linux.makeNixvimWithModule {
    #     module = import ../../modules/home/neovim;
    #   })
    # ];
    imports = [
      # ../../modules/home/yt-dlp
      # inputs.nixvim.homeModules.default
      # ../../modules/home/neovim
      # ../../modules/home/zsh
      # ../../modules/home/git
      # ../../modules/home/ssh
      # ../../modules/home/gh
    ];
  };

  user.shell = "${pkgs.zsh}/bin/zsh";

  # --- GPG CONFIGURATION (MANDATORY ON 25.11) ---
  # Without it, git sign / gpg will crash because it cannot find pinentry
  # environment.etc."gnupg/gpg-agent.conf".text = ''
  #   pinentry-program ${pkgs.pinentry-curses}/bin/pinentry
  # '';

  # These options enable the Home Manager integration
  # home-manager.useGlobalPkgs = true;
  # home-manager.useUserPackages = true;
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
