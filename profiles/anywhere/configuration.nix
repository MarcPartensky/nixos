{ inputs, modulesPath, config, lib, pkgs, ... }:
let
  pkgs-unstable = inputs.unstable.legacyPackages."x86_64-linux";
in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../hosts/anywhere/boot.nix
    ../../hosts/anywhere/lvm.nix
    # ./caddy.nix
    # ../../hosts/anywhere/zfs.nix
    # ../../modules/zsh
  ];

  # Paquets système
  environment.systemPackages = with pkgs; [
    pkgs-unstable.fosrl-pangolin
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
    htop
    which
    # podman
    fastfetch
    bat
    bash
    busybox
    vaultwarden
    pgcli
  ];

  # SSH root avec clé publique (remplace par ta vraie clé)
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    extraConfig = ''
      AllowTcpForwarding yes
      GatewayPorts no   # si tu veux pas exposer le port à l'extérieur
      PermitTunnel yes  # optionnel, pour tunelling plus bas niveau
    '';
  };

  # users.users.root.openssh.authorizedKeys.keys = [
  #   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop" 
  # ];

  programs.zsh.enable = true;

  # systemd.services."entrypoint" = {
  #   description = "entrypoint";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "network-online.target" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.bash}/bin/bash /root/git/nixos/profiles/anywhere/entrypoint.sh";
  #   };
  # };


  # # Exemple d’utilisateur non-root (optionnel mais recommandé)
  # users.users.marc = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # sudo
  #   openssh.authorizedKeys.keys = [
  #     "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop"
  #   ];
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
  system.stateVersion = "25.11";

  # Nix flakes
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # Fuseau horaire
  time.timeZone = "Europe/Paris";
}

