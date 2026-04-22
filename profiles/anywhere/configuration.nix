{
  inputs,
  modulesPath,
  pkgs,
  ...
}: let
  pkgs-unstable = inputs.unstable.legacyPackages."x86_64-linux";
  # pythonEnv = pkgs.python313.withPackages (ps:
  #   with ps; [
  #     # edge-tts
  #   ]);
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../hosts/anywhere/boot.nix
    ../../hosts/anywhere/lvm.nix
    ./cloud.nix

    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.default
    inputs.sops.nixosModules.sops

    ./users.nix
    ./services/traefik
    ./services/postgres
    ./services/vaultwarden
    ./services/nextcloud
    ./services/pangolin
    # ./services/chhoto
    # ./services/eternal-terminal
    # ./services/stalwart
    # inputs.sopswarden.homeManagerModules.default
    # ./caddy.nix
    # ../../hosts/anywhere/zfs.nix

    # inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.default
    inputs.sops.nixosModules.sops
    # inputs.sopswarden.homeManagerModules.default
    # ./services
    ./services/traefik
    ./services/postgres
    ./services/vaultwarden
    # ./services/nextcloud
    ./services/pangolin
    # ./services/chhoto
    # ./services/eternal-terminal
    # ./services/stalwart
  ];

  # Paquets système
  environment.systemPackages = with pkgs;
    [
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
      fzf
      # # wayvnc
      # stow
      ncdu
      htop 
      which
      # podman
      fastfetch
      bat
      # bash
      busybox
      # vaultwarden
      pgcli
      nix-du
      ripgrep # for telescope neovim 
      # gcc
      p7zip
      pangolin-cli
    ];
    # ++ [pythonEnv];

  programs.zsh.enable = true;

  home-manager.users.root = {
    home.stateVersion = "25.11";
    imports = [
      inputs.nixvim.homeModules.default
      ../../modules/home/neovim
      ../../modules/home/zsh
      ../../modules/home/git
      ../../modules/home/ssh
      ../../modules/home/gh
    ];
  };

  sops.defaultSopsFile = ../../secrets/anywhere.yml;

  networking.hostName = "anywhere";

  nix = {
    settings.auto-optimise-store = true;

    optimise = {
      automatic = true;
      dates = ["06:45"]; # Attention: prend une liste de strings, contrairement au gc
    };

    gc = {
      automatic = true;
      dates = "6:30"; # "daily", "weekly", "monthly"
      options = "--delete-older-than 30d";
    };
  };

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
