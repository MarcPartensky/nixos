{
  inputs,
  modulesPath,
  pkgs,
  ...
}: {
  # The VPS routes the tailnet traffic out (exit node): it is the same path as the
  # phone's WireGuard tunnel, with a datacenter throughput instead of tower's
  # residential upload. Routes to approve on the controller side.
  meshTailscale.advertiseExitNode = true;

  # Second AdGuard instance of the tailnet: this VPS is the always-on node, so a
  # resolver here keeps filtering alive while tower reboots and gives roaming
  # devices (phone, laptop, Mac) one that does not depend on the home uplink.
  # Explicit binds: 0.0.0.0:53 is already held by the podman gateways, so listen
  # on loopback plus this node's own mesh address.
  services.dnsFilter.bindHosts = [ "127.0.0.1" "100.64.0.1" ];

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
    # Fleet availability, all three on this VPS and never on tower:
    #  - tuptime   : local uptime/downtime history of the machine;
    #  - zabbix    : server + web frontend, its agents go to the other
    #                machines over the tailnet (local Postgres database, port 9600 on
    #                loopback behind a Pangolin resource);
    #  - uptime-kuma : end-to-end HTTP/TCP probes of the public domains.
    ../../services/tuptime
    ../../services/zabbix/server.nix
    ../../services/zabbix/agent.nix
    ../../services/uptime-kuma
    # ../../services/nextcloud
    # ../../services/oxicloud
    ../../services/zitadel
    ../../services/pangolin
    ../../services/pangolin/gerbil-wg0-ensure.nix
    ../../services/pangolin/wg0-runtime-guard.nix
    ../../services/wireguard
    # headscale mesh: server on this VPS (services/headscale) + tailscale
    # node (services/tailscale, shared key secrets/headscale.yml).
    ../../services/headscale
    ../../services/tailscale
    # Filtering resolver of the tailnet, duplicated: here (always-on node, and
    # colocated with the internet exit node) and on tower (neighbor of the home).
    # It is headscale that pushes these two IPs to ALL the tailnet devices,
    # so no per-device DNS setting. Port 53 is not open on the firewall:
    # tailscale0 is trusted, the resolver only listens on the mesh. Lists and
    # short names are shared with tower (services/adguard/tailnet.nix): the
    # client queries both in parallel, a divergence would make the
    # filtering vary depending on who answers first.
    ../../services/adguard
    ../../services/adguard/tailnet.nix
    # ./services/chhoto
    ../../services/eternal-terminal
    ../../services/stalwart
    # ygg-mesh private network (Yggdrasil via Tor + direct LAN link), members:
    # tower, anywhere, deck. See services/ygg-mesh/default.nix.
    ../../services/ygg-mesh
    ../../services/droplify
    # Gotify server (postgres database + Pangolin resource of the `rack` site):
    # moved from tower on 20/11/2026. tower only keeps the
    # consumers (gotify-matrix bridge, mesh-dashboard, gateway hook).
    ../../services/gotify
    ../../services/hermes
    # Windmill worker: takes jobs from tower's windmill database via the
    # tailnet. The VPS is always on: it is the "always available" node.
    ../../services/windmill
    # ../../services/vaultwarden-mcp  # sops secret secrets/tower.yml, unreadable on this VPS: broke setupSecrets
  ];

  services.windmillFleet = {
    enable = true;
    role = "worker";
    dbHost = "100.64.0.3";
    workerGroup = "anywhere";
    workers = 2;
    baseUrl = "https://windmill.marcpartensky.com";
  };

  # hermes gateway disabled on the VPS: inert (no Matrix/Discord token,
  # DirectSDK model without claude login) and it pulled claude-code (unfree) into
  # the build. The hermes user + sudo nixos-rebuild remain (remote
  # deployment from tower).
  services.hermes.enableAgent = false;

  # WebSocket tunnel (NixOS module `services.wstunnel`): the server runs here,
  # Traefik publishes it as wss://ws.marcpartensky.com (route in
  # services/traefik/dynamic.toml). It speaks plain HTTP on loopback, TLS is
  # terminated by Traefik. Allowed targets: the VPS sshd (SSH-over-wss from
  # tower), the phone's sshd and the SOCKS5/HTTP proxies the phone publishes,
  # both exiting with its IP.
  services.wstunnel = {
    enable = true;
    servers.vps = {
      listen = {
        host = "127.0.0.1";
        port = 8444;
        enableHTTPS = false;
      };
      settings.restrict-to = [
        {
          host = "127.0.0.1";
          port = 22;
        }
        {
          host = "127.0.0.1";
          port = 2225;
        }
        {
          host = "127.0.0.1";
          port = 1081;
        }
        {
          host = "127.0.0.1";
          port = 1082;
        }
      ];
    };
  };

  # System packages
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

  # The services/gotify module is shared with tower: on this VPS there is neither
  # newt (Pangolin `rack` site, local type) nor pg_hba to impose (the local
  # loopback is already in trust and other databases live in the same cluster).
  services.gotify.publishViaNewt = false;
  services.gotify.managePostgresAuth = false;

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

  # marc's HM desktop DISABLED on this host: it pulled firefox/electron/cursor/
  # libreoffice/cef (32.9 GiB of missing paths) into the VPS closure, on a
  # 46 G disk with 9.8 free - that is what already filled `/` and made
  # pangolin/traefik fall on 09/11/2026. The VPS has no screen.
  # home-manager.users.marc = {
  #   home.stateVersion = "25.11";
  #   sops.age.keyFile = "/home/marc/.config/sops/age/keys.txt";
  #   imports = [ ../../users/marc/home.nix ];
  # };

  networking.hostName = "anywhere";

  nix = {
    settings.auto-optimise-store = true;

    optimise = {
      automatic = true;
      dates = ["06:45"]; # Warning: takes a list of strings, unlike gc
    };

    gc = {
      automatic = true;
      dates = "6:30"; # "daily", "weekly", "monthly"
      # "30d" was letting ~18 G of old generations accumulate on a
      # 46 G disk: on 12/10/2026 the disk rose to 100%, pangolin-pre-start
      # failed (No space left on device) and traefik/gerbil fell in cascade
      # (nothing left on 80/443). 14 d are enough (marc deploys at most a few times
      # per month) and leave some margin.
      options = "--delete-older-than 14d";
    };
  };

  # Without a cap, journald grows to 10% of the disk (default): 4.1 G out of 46 G, which
  # contributed to the saturation of 12/10/2026. 500 M is enough to debug a
  # recent failure.
  services.journald.extraConfig = "SystemMaxUse=500M";

  # SSH root with public key (replace with your real key)
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    extraConfig = ''
      AllowTcpForwarding yes
      GatewayPorts no   # if you do not want to expose the port externally
      PermitTunnel yes  # optional, for lower-level tunneling
    '';
  };

  # Declarative root keys. NixOS writes them into /etc/ssh/authorized_keys.d/root
  # and sshd ALSO reads ~/.ssh/authorized_keys: this list adds to the keys already
  # placed by hand, it removes none.
  users.users.root.openssh.authorizedKeys.keys = [
    # hermes agent on tower: lets it deploy and diagnose this VPS
    # (stalwart, pangolin, zitadel) without going through a copy-paste from marc.
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

  # # Example of a non-root user (optional but recommended)
  # users.users.marc = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # sudo
  #   openssh.authorizedKeys.keys = [
  #     "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc6adJwUI+Un2hCAfGfJ7uD5oM1WWz/ct3w93rvSuG5 xiaomi-laptop"
  #   ];
  # };

  security.sudo.enable = true;

  # Backup etc files instead of failing to activate generation if a file already exists
  # environment.etcBackupExtension = ".bak";

  # NixOS system version
  system.stateVersion = "25.11";

  # Nix flakes
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # Time zone
  time.timeZone = "Europe/Paris";
}
