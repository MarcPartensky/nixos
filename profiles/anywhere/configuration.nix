{
  inputs,
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../hosts/anywhere/boot.nix
    ../../hosts/anywhere/lvm.nix
    ./cloud.nix
    # ./caddy.nix

    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.default
    inputs.sops.nixosModules.sops
    inputs.hermes-agent.nixosModules.default
    # inputs.sopswarden.homeManagerModules.default

    ../../services/traefik
    ../../services/postgres
    ../../services/vaultwarden
    # ../../services/nextcloud
    # ../../services/oxicloud
    ../../services/zitadel
    ../../services/pangolin
    ../../services/pangolin/gerbil-wg0-ensure.nix
    ../../services/wireguard
    # ../../services/tailscale # desactive 26/09: exige le secret sops tailscale/auth_key (absent de secrets/anywhere.yml). Reactiver avec le mesh.
    ../../services/headscale
    # ./services/chhoto
    ../../services/eternal-terminal
    ../../services/stalwart
    # Réseau privé ygg-mesh (Yggdrasil via Tor + lien direct LAN), membres :
    # tower, anywhere, deck. Voir services/ygg-mesh/default.nix.
    ../../services/ygg-mesh
    ../../services/droplify
    ../../services/hermes
    # ../../services/vaultwarden-mcp  # secret sops secrets/tower.yml, illisible sur ce VPS : cassait setupSecrets
  ];

  # Gateway hermes coupé sur le VPS : inerte (pas de token Matrix/Discord,
  # modèle DirectSDK sans login claude) et il tirait claude-code (unfree) dans
  # le build. L'utilisateur hermes + sudo nixos-rebuild restent (déploiement
  # remote depuis tower).
  services.hermes.enableAgent = false;

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
      sops
      ssh-to-age
      # # wayvnc
      # stow
      ncdu
      htop 
      which
      # podman
      fastfetch
      bat
      eza
      # bash
      # busybox
      # vaultwarden
      pgcli
      # nix-du
      ripgrep # for telescope neovim 
      jq
      # gcc
      # p7zip
      # pangolin
      tmux

      httpie
      tree
      parted
    ];
    # ++ [pythonEnv];

  programs.zsh.enable = true;


  sops.defaultSopsFile = ../../secrets/anywhere.yml;

  sops.secrets."anthropic_api_key" = {
    sopsFile = ../../secrets/common.yml;
    owner = "root";
  };

  home-manager.extraSpecialArgs = {inherit inputs;};
  home-manager.users.root = {
    home.stateVersion = "25.11";
    # sops.age.keyFile = "/root/.config/sops/age/keys.txt";
    imports = [
      inputs.nixvim.homeModules.default
      # inputs.sops.homeModules.sops
      ../../modules/home/claude-commit
      ../../modules/home/neovim
      ../../modules/home/zsh
      ../../modules/home/git
      ../../modules/home/ssh
      ../../modules/home/zellij
      # ../../modules/home/gh
    ];
  };

  home-manager.users.marc = {
    home.stateVersion = "25.11";
    sops.age.keyFile = "/home/marc/.config/sops/age/keys.txt";
    imports = [ ../../users/marc/home.nix ];
  };

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
      # "30d" laissait s'accumuler ~18 G de vieilles generations sur un disque de
      # 46 G : le 12/10/2026 le disque est monte a 100 %, pangolin-pre-start a
      # echoue (No space left on device) et traefik/gerbil sont tombes en cascade
      # (plus rien sur 80/443). 14 j suffisent (marc deploie au plus quelques fois
      # par mois) et laissent de la marge.
      options = "--delete-older-than 14d";
    };
  };

  # Sans cap, journald monte a 10 % du disque (defaut) : 4,1 G sur 46 G, ce qui a
  # contribue a la saturation du 12/10/2026. 500 M suffisent pour debugger une
  # panne recente.
  services.journald.extraConfig = "SystemMaxUse=500M";

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

  # Clés root déclaratives. NixOS les écrit dans /etc/ssh/authorized_keys.d/root
  # et sshd lit AUSSI ~/.ssh/authorized_keys : cette liste s'ajoute aux clés déjà
  # posées à la main, elle n'en retire aucune.
  users.users.root.openssh.authorizedKeys.keys = [
    # Agent hermes sur tower : lui permet de déployer et diagnostiquer ce VPS
    # (stalwart, pangolin, zitadel) sans passer par un copier-coller de marc.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
    # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop"
  ];

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
