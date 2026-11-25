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
    ../../modules/nixos/nixos-rebuild-gated
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
    # Fleet availability: local history (tuptime) + Zabbix agent
    # toward the server that lives on the VPS, over the tailnet.
    ../../services/tuptime
    ../../services/zabbix/agent.nix
    # ygg-mesh private network (Yggdrasil via Tor + direct LAN link), members:
    # tower, anywhere, deck. See services/ygg-mesh/default.nix.
    ../../services/ygg-mesh
    # headscale mesh: tailscale node (controller on the anywhere VPS, cf
    # services/headscale and services/tailscale).
    ../../services/tailscale
    # Trust in the tailnet's internal CA: without it, the short names of the
    # tower proxy (`https://mesh`, `https://jellyfin`) fail with
    # "unable to get local issuer certificate".
    ../../modules/nixos/intra-ca-trust.nix
    # Windmill worker: takes jobs from tower's windmill database via the
    # tailnet (Postgres 100.64.0.3:5432, windmill role in scram). No port
    # open here, no local state: the deck can sleep, the job is
    # replayed by Windmill on return.
    ../../services/windmill
    ../../modules/nixos/panel-idle-off
    ./switch-emu.nix
  ];

  services.windmillFleet = {
    enable = true;
    role = "worker";
    dbHost = "100.64.0.3";
    workerGroup = "deck";
    workers = 2;
    baseUrl = "https://windmill.marcpartensky.com";
  };

  jovian.devices.steamdeck = {
    enable = true;
    enableVendorDrivers = false; # the Valve Mesa build crashed, we stay on upstream Mesa
    autoUpdate = true; # BIOS + controller firmware at boot, like SteamOS
    enableGyroDsuService = true; # gyroscope for emulators (Cemu, Dolphin)
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

  security.rtkit.enable = true; # was provided by your bluetooth module

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

  programs.zsh.enable = true; # required by users.nix
  services.openssh.enable = true;
  services.automatic-timezoned.enable = false;

  # --- Dedicated account for the hermes agent (tower) ---
  # Deck does NOT import services/hermes (no chat bot here): the
  # system account is therefore declared by hand. Direct shell access (et-session +
  # zellij, cf services/eternal-terminal already imported above) + sudo
  # NOPASSWD nixos-rebuild to be able to build on site.
  # Mac key for marc: `ssh deck` from the Mac goes through rack
  # (ProxyJump), the final authentication is end-to-end with the
  # Mac key. The RSA key from users.nix remains valid.
  users.users.marc.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
  ];

  users.groups.hermes = {};
  users.users.hermes = {
    isSystemUser = true;
    group = "hermes";
    home = "/var/lib/hermes";
    createHome = true;
    shell = pkgs.zsh;
    # Lets the agent read `journalctl -u <service>` on the Deck.
    extraGroups = [ "systemd-journal" ];
    # KF3hu = hermes@tower (rebuild/diagnostic from tower or the LAN).
    # MTNk2 = hermes@laptop (the laptop agent can also reach the Deck).
    # gpwx  = root@anywhere (the VPS reaches the Deck via the wg1 tunnel -> tower,
    #         once tower is LAN router).
    # MdX5  = marc@Air-de-Marc (the Mac, for `ssh deck` via ProxyJump rack).
    # nix-builder@tower = tower nix-daemon key pair: the Deck serves as a
    #         remote builder (nix.buildMachines of profiles/tower + load-based
    #         selection in modules/nixos/nixos-rebuild-gated).
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTNk2eJYoD87QP/Ajg6iCX/EwYCjVVvoTfTAFqh2qnW hermes@laptop"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAc2f6U09CWD2yQNcyGz6Pz9EN3aJzvdCvr7FrSSgpwx root@anywhere"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItlIA6k7s5q58FQBvof2aJ5ZljvA2vhhhRJqap6uVCb nix-builder@tower"
    ];
  };

  # The Deck is a remote builder of tower: tower's daemon connects to it as
  # hermes and asks it to compile. Without hermes in trusted-users, the Deck
  # refuses to serve the results (nix store ping -> Trusted: 0, observed on
  # 25/11/2026). Same rule as profiles/common for the laptop.
  nix.settings.trusted-users = [ "root" "hermes" ];

  # hermes no longer has nixos-rebuild directly: the nixos-rebuild-gated module sets
  # the wrapper that refuses --impure and serializes rebuilds (import below,
  # at the top of this file).

  systemd.sleep.settings.Sleep = {
    AllowSuspend = false;
    AllowHibernation = false; # also cuts hybrid-sleep and suspend-then-hibernate
  };

  # The roommate's complaint: the panel stayed lit for days. Steam's own
  # "Turn off screen after" only dims the backlight to ~3 % under gamescope, so
  # the deck cuts the backlight itself after 5 min without input (keyboard or
  # gamepad) and brings it back at the first input. No suspend: the machine keeps
  # building and mining. Cf modules/nixos/panel-idle-off.
  services.panelIdleOff = {
    enable = true;
    idleSeconds = 300;
  };

  # ========================================================================
  # MATRIX CONDUIT (replaces Synapse on tower)
  # ========================================================================
  services.matrix-conduit = {
    enable = true;
    settings = {
      global = {
        server_name = "matrix.marcpartensky.com";
        address = "127.0.0.1"; # IPv6 is disabled on the Deck, default ::1 breaks conduit
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

    # AppID = the number in the store URL, e.g. store.steampowered.com/app/1091500
    apps."1091500".compatTool = pkgs.proton-ge-bin;

    nonSteamApps = {
      "Dolphin".target = pkgs.dolphin-emu;
      "Ryubing".target = pkgs.ryubing;
      "Eden".target = pkgs.eden;
      # The "Mario Kart 8 Deluxe" tile lives in switch-emu.nix: it goes
      # through the mk8dx script, which picks the dump present in ~/Games/switch.
    };
  };

  systemd.timers.deck-wake-downloads = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 01:55:00";
      WakeSystem = true; # wakes from sleep via the RTC clock
    };
  };

  # coreutils' `sleep` does not accept a compound duration like "5h35m" (a
  # single unit per argument, but several arguments are added): the
  # form "5h35m" failed with "invalid time interval" and the unit failed on
  # each trigger. 5h35m = 20100 s.
  #
  # Only the `sleep` inhibit is kept: the `idle` one asked logind to keep the
  # DISPLAY awake, which contradicts the panel blanking below (a download does
  # not need a lit screen). Downloads still get their five hours.
  systemd.services.deck-wake-downloads.serviceConfig.ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep --why='Steam downloads' ${pkgs.coreutils}/bin/sleep 20100";

  # home.file.${config.gtk.gtk2.configLocation}.force = true;
  # xdg.configFile = {
  #   "gtk-3.0/settings.ini".force = true;
  #   "gtk-4.0/settings.ini".force = true;
  #   "gtk-4.0/gtk.css".force = true;
  # };

  # Monero mining (RandomX, CPU only). 8 threads = max hashrate on the
  # 4 cores / 8 threads of the Van Gogh; the thermal ceiling and the
  # charge ceiling protect the machine over the long term.
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

  # Local LLM/VLM inference on the RDNA2 GPU (Van Gogh, RADV). The deck is the
  # only always-on machine with a GPU and it never suspends (services.panelIdleOff
  # blanks the panel instead of sleeping), so it hosts the vision models: the
  # winnie ingest points its OLLAMA_URL here.
  # `ollama-vulkan` is the nixpkgs build with the Vulkan backend (no CUDA/ROCm),
  # and `OLLAMA_IGPU_ENABLE` is mandatory: ollama drops integrated GPUs unless it
  # is set, which is exactly what happened before this option existed (the server
  # only ever listed the CPU as an inference device).
  # Measured on qwen3-vl:4b (1043 image tokens, 183 generated): 86 tok/s prefill
  # and 22 tok/s decode, against 4.7 and 3.3 tok/s on tower's CPU.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    host = "0.0.0.0";
    port = 11434;
    loadModels = [ "qwen3-vl:4b" ];
    environmentVariables.OLLAMA_IGPU_ENABLE = "1";
  };

  # Ollama has no authentication: this port is open on the LAN and the tailnet
  # only, which is how the other deck services are exposed.
  networking.firewall.allowedTCPPorts = [ 11434 ];

  networking.hostName = "deck";
  system.stateVersion = "26.05";
}
