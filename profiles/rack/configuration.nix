{ config, lib, pkgs, ... }:

{
  imports = [
    # ./hardware-configuration.nix
    # ./modules/sshd
    # ../../nod-sshd
    # ../../zsh
  ];

  # Paquets système
  environment.systemPackages = with pkgs; [
    procps
    killall
    nano
    openssh
    iproute2
    shadow
    neovim
    zsh
    git
    gh
    just
    # wayvnc
    stow
    ncdu
    # pangolin
    htop
    which
    # podman
    fastfetch
  ];

  # SSH root avec clé publique (remplace par ta vraie clé)
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop" 
  ];

  # Exemple d’utilisateur non-root (optionnel mais recommandé)
  users.users.marc = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # sudo
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop"
    ];
  };
  security.sudo.enable = true;

  # Bootloader
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda"; # ou /dev/vda selon ton VPS

  # Backup etc files instead of failing to activate generation if a file already existe
  # environment.etcBackupExtension = ".bak";

  # Version du système NixOS
  system.stateVersion = "24.05";

  # Nix flakes
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # Fuseau horaire
  time.timeZone = "Europe/Paris";
}

