# Base commune des VM de dev microvm.nix (input `microvm` du flake).
#
# Une VM = ce module + vms/<nom>.nix + deux entrées dans flake.nix
# (nixosConfigurations.<nom> et packages.x86_64-linux.<nom>).
# Exemple complet et mode d'emploi : vms/dev.nix.
#
# Pourquoi le build est rapide :
#   - le /nix/store de tower est partagé en 9p (lecture seule) : aucune image
#     squashfs/erofs de store n'est construite, et tout ce que tower a déjà
#     construit ou téléchargé est directement disponible dans la VM
#     (`nix shell`, `nix develop`, exécuter un binaire du store : 0 build) ;
#   - même nixpkgs que l'hôte : le noyau invité est le dérivé de
#     boot.kernelPackages de tower, donc déjà en store ;
#   - /nix/store est monté par-dessus un overlay écrivable posé sur un petit
#     disque (nix-store-overlay.img) : `nix build` fonctionne DANS la VM.
# Le reste (/ /var /home) est un tmpfs : chaque démarrage repart propre.
{
  config,
  lib,
  pkgs,
  ...
}: {
  microvm = {
    hypervisor = "qemu";

    # optimize = false : microvm.nix compile sinon une variante de qemu sans
    # GUI (`minimal = true`) qui n'est dans aucun cache binaire (28 min de
    # compilation locale) ET qui est compilée sans le réseau user de qemu
    # (slirp) : `-netdev user` échoue donc au démarrage. Le qemu_kvm standard
    # (même version, avec slirp) est en cache.nixos.org : rien à construire.
    optimize.enable = false;

    # Ressources ; surcharger dans vms/<nom>.nix. NE PAS mettre mem = 2048
    # (valeur exacte qui bloque qemu, cf. microvm.nix#171).
    vcpu = lib.mkDefault 4;
    mem = lib.mkDefault 4096;

    shares = [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        # 9p est intégré à qemu (pas besoin de virtiofsd, contrairement à
        # proto = "virtiofs" qui suppose le module hôte microvm + systemd).
        proto = "9p";
      }
    ];

    # Overlay écrivable du store : lower = /nix/.ro-store, upper = le disque
    # ci-dessous. Le disque est créé au premier lancement (chemin relatif au
    # répertoire d'état depuis lequel tourne le runner, cf. recette `just vm`).
    writableStoreOverlay = "/nix/.rw-store";
    volumes = [
      {
        image = "nix-store-overlay.img";
        mountPoint = config.microvm.writableStoreOverlay;
        size = 8192; # Mo, fichier sparse (n'occupe que ce qui est écrit)
      }
    ];

    # Réseau slirp (user) : la VM sort sur Internet, et les ports de
    # forwardPorts sont redirigés depuis tower (bind 127.0.0.1 uniquement).
    interfaces = [
      {
        type = "user";
        id = "user";
        mac = "02:00:00:1f:1d:01"; # changer par VM (cosmétique, réseaux isolés)
      }
    ];
    forwardPorts = [
      # ssh dans la VM depuis tower
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 2222;
        guest.port = 22;
      }
    ];

    # Pas de fenêtre graphique : la console s'affiche en série dans le terminal
    # qui lance la VM (qemu -nographic), avec autologin de marc.
    graphics.enable = false;
  };

  # --- Optimisations de démarrage ---
  # `microvm.optimize.enable = false` plus haut empêche de récupérer celles du
  # module microvm (il les couple à un qemu sans slirp) : on les reprend ici
  # telles quelles, sans toucher au paquet qemu.
  documentation.enable = lib.mkDefault false; # les docs pèsent lourd, inutiles en VM
  boot = {
    initrd.systemd.enable = lib.mkDefault true; # initrd systemd : démarrage bien plus rapide
    swraid.enable = lib.mkDefault false;
    kernelParams = ["8250.nr_uarts=1"]; # une seule console série
  };
  networking.useNetworkd = lib.mkDefault true; # networkd plutôt que dhcpcd (plus rapide)
  systemd.network.wait-online.enable = lib.mkDefault false; # bug systemd#29388
  systemd.tpm2.enable = lib.mkDefault false;

  # --- Système invité minimal ---
  system.stateVersion = "25.11";
  networking.hostName = lib.mkDefault "vm-dev"; # vms/<nom>.nix met le vrai nom
  networking.useDHCP = true; # l'interface slirp a besoin d'un bail DHCP
  networking.firewall.enable = false; # NAT ; seuls les ports de forwardPorts sont joignables

  time.timeZone = "America/New_York";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  # Console série : shell direct en marc (bac à sable local, jetable).
  services.getty.autologinUser = "marc";

  users.users.marc = {
    isNormalUser = true;
    description = "Marc Partensky";
    shell = pkgs.zsh;
    extraGroups = ["wheel" "kvm"];
    # Même hash que users.nix (celui de tower) : login console par mot de passe
    # possible si l'autologin est retiré.
    hashedPassword = "$6$dE28cUDZ9G81wzwo$JoO.6M91zdtR0ja/g1pw/LKE8aAMugmGkIyOiSuqdjEWVKId9F2jxqdvh5Bo69uOC3/g7uP6O3mZmzxqD2pKU1";
    openssh.authorizedKeys.keys = [
      # clé de marc (users.nix)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com"
      # clé de l'agent hermes (debug / aide depuis tower)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
    ];
  };
  security.sudo.wheelNeedsPassword = false; # configuration jetable

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "marc"];
    # ne pas activer auto-optimise-store : incompatible avec writableStoreOverlay
  };

  # Volontairement léger : tout le reste se récupère depuis le store partagé de
  # tower (`nix shell`/`nix develop`) ou s'ajoute dans vms/<nom>.nix.
  environment.systemPackages = with pkgs; [
    curl
    fd
    git
    htop
    jq
    just
    neovim
    ripgrep
    rsync
    tmux
    tree
    unzip
    vim
    wget
  ];

  # /home est un tmpfs recréé à chaque démarrage : sans ~/.zshrc, zsh lance son
  # assistant "nouvel utilisateur" à chaque connexion. On dépose un rc minimal.
  system.activationScripts.vm-zshrc = ''
    install -D -o marc -g users -m 0644 ${pkgs.writeText "vm-zshrc" "# VM de dev jetable : ports redirigés listés dans le motd\nautoload -Uz compinit && compinit -C\nalias ll='ls -alF'\nexport EDITOR=nvim\n"} /home/marc/.zshrc
  '';

  # motd généré depuis microvm.forwardPorts : la correspondance des ports
  # VM -> tower s'affiche à la connexion (et suit toute modif des forwards).
  # Depuis 26.05 users.motd n'écrit plus /etc/motd : pam_motd l'affiche en
  # direct, et les modules sshd/login l'activent déjà (showMotd = true).
  users.motd = let
    sshRule = lib.findFirst (p: p.guest.port == 22) null config.microvm.forwardPorts;
    appRules = builtins.filter (p: p.guest.port != 22) config.microvm.forwardPorts;
    addr = p: if p.host.address == "" then "127.0.0.1" else p.host.address;
  in ''
    VM de dev microvm.nix : /nix/store de tower partagé.
    ${lib.optionalString (sshRule != null) "  ssh depuis tower  : ssh -p ${toString sshRule.host.port} marc@127.0.0.1\n"}${lib.concatMapStringsSep "\n" (p: "  port VM ${toString p.guest.port}  ->  http://${addr p}:${toString p.host.port} sur tower") appRules}
      code de l'hôte   : microvm.shares (voir vms/<nom>.nix)
      arrêt            : poweroff, ou <état>/current/bin/microvm-shutdown
  '';
}
