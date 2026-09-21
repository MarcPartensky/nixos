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

  programs.zsh.enable = true; # requis par users.nix
  services.openssh.enable = true;
  services.automatic-timezoned.enable = false;

  systemd.sleep.settings.Sleep = {
    AllowSuspend = false;
    AllowHibernation = false; # coupe aussi hybrid-sleep et suspend-then-hibernate
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

  # home.file.${config.gtk.gtk2.configLocation}.force = true;
  # xdg.configFile = {
  #   "gtk-3.0/settings.ini".force = true;
  #   "gtk-4.0/settings.ini".force = true;
  #   "gtk-4.0/gtk.css".force = true;
  # };

  networking.hostName = "deck";
  system.stateVersion = "26.05";
}
