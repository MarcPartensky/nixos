{ config, lib, pkgs, inputs, ... }:

{

  imports = [
  # ./modules/sshd
  # ../../nod-sshd
    # ../../zsh
    # ../../services/postgres
    # ../../services/nextcloud
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
    gemini-cli
    tmate
    bat
    exa
  ];

  home-manager.config = {
    home.stateVersion = "25.11";
    imports = [ 
      inputs.nixvim.homeModules.default 
      ../../modules/home/neovim
      # ../../modules/home/zsh
      # ../../modules/home/git
      # ../../modules/home/ssh
      ../../modules/home/gh
    ];
  };

    
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
  system.stateVersion = "25.11";


  # Set up nix for flakes
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # Set your time zone
  time.timeZone = "Europe/Paris";
}
