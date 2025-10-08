{ modulesPath, config, lib, pkgs, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../hosts/anywhere/boot.nix
    ../../hosts/anywhere/lvm.nix
    ./cloud.nix
    # ../../hosts/anywhere/zfs.nix
    # ../../modules/zsh
  ];

  # Paquets système
  environment.systemPackages = with pkgs; [
    procps
    killall
    openssh
    iproute2
    shadow
    neovim
    zsh
    git
    gh
    just
    # # wayvnc
    stow
    ncdu
    pangolin
    htop
    which
    # podman
    fastfetch
  ];

  # SSH root avec clé publique (remplace par ta vraie clé)
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  # users.users.root.openssh.authorizedKeys.keys = [
  #   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop" 
  # ];

  programs.zsh.enable = true;

  # # Exemple d’utilisateur non-root (optionnel mais recommandé)
  # users.users.marc = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # sudo
  #   openssh.authorizedKeys.keys = [
  #     "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop"
  #   ];
  # };

  # Exemple de dossier pour Nextcloud (Docker ou systemd service)
  # services.nextcloud = {
  #   enable = true;
  #   dataDir = "/var/lib/nextcloud/data";
  #   dbType = "sqlite"; # ou "mysql" si tu préfères
  # };

  # Pangolin (si tu utilises pangolin-service de nixpkgs)
  # services.pangolin = {
  #   enable = true;
  #   # config par défaut, tu peux préciser ports ou options ici
  # };

  security.sudo.enable = true;

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

