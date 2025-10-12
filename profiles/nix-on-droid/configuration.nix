{ config, lib, pkgs, ... }:

{

  imports = [
  # ./modules/sshd
  # ../../nod-sshd
    # ../../zsh
    ../../services/postgres
    ../../services/nextcloud
  ];

  # Simply install just the packages
  environment.packages = with pkgs; [

    # Some common stuff that people expect to have
    procps
    killall
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
    pangolin
    htop
    which
    podman
    neofetch
  ];

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
