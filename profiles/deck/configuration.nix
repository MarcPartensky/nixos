{
  lib,
  pkgs,
  inputs,
  config,
  ...
}: {
  imports = [
    inputs.steam-config-nix.nixosModules.default
    inputs.disko.nixosModules.disko
    inputs.sops.nixosModules.sops
    ../../users.nix
    ../../hosts/deck/disko.nix
    ../../hosts/deck/hardware-configuration.nix
    ../../modules/nixos/networking
    ../../modules/nixos/pipewire
    ../../modules/nixos/xdg
    ../../modules/nixos/jovian
    ../../services/eternal-terminal
    ../../services/matrix-conduit
    ../../services/nginx-matrix
    ../../services/llm-steamdeck
    ../../services/monero-miner
    # Réseau privé ygg-mesh (Yggdrasil via Tor + lien direct LAN), membres :
    # tower, anywhere, deck. Voir services/ygg-mesh/default.nix.
    ../../services/ygg-mesh
    ./switch-emu.nix
  ];

  jovian.devices.steamdeck = {
    enable = true;
    enableVendorDrivers = false; # le build de Mesa Valve plantait, on reste sur Mesa upstream
    autoUpdate = true; # BIOS + firmware manette au boot, comme SteamOS
    enableGyroDsuService = true; # gyroscope pour émulateurs (Cemu, Dolphin)
  };

  jovian.decky-loader.enable = false;

  services.desktopManager.plasma6.enable = true;
  jovian.steam.desktopSession = lib.mkForce "plasma";

  environment.systemPackages = with pkgs; [
    home-manager
    just
    git
    neovim
    htop
    neovim
    (makeDesktopItem {
      name = "return-to-gaming-mode";
      desktopName = "Return to Gaming Mode";
      exec = "steamos-session-select gamescope";
      icon = "steam";
      categories = ["Game"];
    })
  ];

  time.timeZone = "America/New_York";

  security.rtkit.enable = true; # était fourni par ton module bluetooth

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  nixpkgs.config.allowUnfree = true;
  sops.defaultSopsFile = ../../secrets/common.yml;

  sops.secrets."monero/wallet" = {
    sopsFile = ../../secrets/monero-deck.yml;
    key = "wallet";
    owner = "root";
    mode = "0400";
  };
  sops.secrets."monero/nextcloud-user" = {
    sopsFile = ../../secrets/common.yml;
    key = "nextcloud_user";
    owner = "root";
    mode = "0400";
  };
  sops.secrets."monero/nextcloud-password" = {
    sopsFile = ../../secrets/common.yml;
    key = "nextcloud_password";
    owner = "root";
    mode = "0400";
  };

  programs.zsh.enable = true; # requis par users.nix
  services.openssh.enable = true;
  services.automatic-timezoned.enable = false;

  # --- Compte dédié pour l'agent hermes (tower) ---
  # Deck n'importe PAS services/hermes (pas de bot chat ici) : le compte
  # système est donc déclaré à la main. Accès shell direct (et-session +
  # zellij, cf services/eternal-terminal déjà importé plus haut) + sudo
  # NOPASSWD nixos-rebuild pour pouvoir builder sur place.
  users.groups.hermes = {};
  users.users.hermes = {
    isSystemUser = true;
    group = "hermes";
    home = "/var/lib/hermes";
    createHome = true;
    shell = pkgs.zsh;
    # Permet a l'agent de lire `journalctl -u <service>` sur le Deck.
    extraGroups = [ "systemd-journal" ];
    # KF3hu = hermes@tower (rebuild/diagnostic depuis tower ou le LAN).
    # gpwx  = root@anywhere (le VPS joint le Deck par le tunnel wg1 -> tower,
    #         une fois tower routeur du LAN).
    # MdX5  = marc@Air-de-Marc (le Mac, pour `ssh deck` via ProxyJump rack).
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAc2f6U09CWD2yQNcyGz6Pz9EN3aJzvdCvr7FrSSgpwx root@anywhere"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
    ];
  };

  security.sudo.extraRules = [
    {
      users = ["hermes"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
        {
          command = "/nix/store/*-nixos-rebuild/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = false;
    AllowHibernation = false; # coupe aussi hybrid-sleep et suspend-then-hibernate
  };

  # ========================================================================
  # MATRIX CONDUIT (replaces Synapse on tower)
  # ========================================================================
  services.matrix-conduit = {
    enable = true;
    settings = {
      global = {
        server_name = "matrix.marcpartensky.com";
        address = "127.0.0.1"; # IPv6 est desactive sur le Deck, ::1 par defaut casse conduit
        database_backend = "rocksdb";
        port = 6167;
        allow_registration = false;
        allow_federation = true;
        trusted_servers = [ "matrix.org" ];
        max_request_size = 20000000;
      };
      federation = {
        port = 8448;
      };
    };
  };

  # ========================================================================
  # NGINX REVERSE PROXY FOR MATRIX
  # ========================================================================
  services.nginx-matrix = {
    enable = true;
    domain = "matrix.marcpartensky.com";
    upstream_host = "127.0.0.1";
    upstream_port = 6167;
    federation_port = 8448;
    listen_port = 8008;
    acme = false; # TLS terminated by Pangolin on VPS
  };

  programs.steam.config = {
    enable = true;

    # AppID = le nombre dans l'URL du store, ex. store.steampowered.com/app/1091500
    apps."1091500".compatTool = pkgs.proton-ge-bin;

    nonSteamApps = {
      "Dolphin".target = pkgs.dolphin-emu;
      "Ryubing".target = pkgs.ryubing;
      "Eden".target = pkgs.eden;

      # optionnel : une tuile par jeu en Gaming Mode, lancé directement en plein écran
      "Mario Kart 8 Deluxe" = {
        target = pkgs.eden;
        args = ["-f" "-g" "/home/marc/Games/switch/mario-kart-8.nsp"];
      };
    };
  };

  systemd.timers.deck-wake-downloads = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 01:55:00";
      WakeSystem = true; # réveille depuis la veille via l'horloge RTC
    };
  };

  systemd.services.deck-wake-downloads.serviceConfig.ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:idle --why='Téléchargements Steam' ${pkgs.coreutils}/bin/sleep 5h35m";

  # home.file.${config.gtk.gtk2.configLocation}.force = true;
  # xdg.configFile = {
  #   "gtk-3.0/settings.ini".force = true;
  #   "gtk-4.0/settings.ini".force = true;
  #   "gtk-4.0/gtk.css".force = true;
  # };

  # Minage Monero (RandomX, CPU uniquement). 8 threads = hashrate max sur les
  # 4 coeurs / 8 threads du Van Gogh ; le plafond thermique et le plafond de
  # charge protegent la machine sur le long terme.
  services.monero-miner = {
    enable = true;
    walletFile = config.sops.secrets."monero/wallet".path;
    pool = "gulf.moneroocean.stream:10008";
    tls = false;
    threads = 6;
    cpuQuota = 600;
    rigId = "steamdeck";
    chargeLimit = 80;
    thermalGuard.enable = true;
    thermalGuard.maxTemperature = 88;
    thermalGuard.resumeTemperature = 84;
    schedule.enable = true;
    calendar.enable = true;
    calendar.userFile = config.sops.secrets."monero/nextcloud-user".path;
    calendar.passwordFile = config.sops.secrets."monero/nextcloud-password".path;
    calendar.calendars = [ "sg" ];
  };

  networking.hostName = "deck";
  system.stateVersion = "26.05";
}
