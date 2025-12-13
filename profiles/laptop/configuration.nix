# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, inputs, ... }:
let
    packages = import ./packages.nix { inherit pkgs inputs; };
in {
  imports =
    [ # Include the results of the hardware scan.
      # ../../services
      ../../hosts/laptop/networking.nix
      ../../hosts/laptop/bluetooth.nix
			../../modules/nixos/iso
      ../../modules/nixos/pipewire
      ../../modules/nixos/keyd
      ../../modules/nixos/gnupg
      # ../../modules/generations
      # ../../modules/git
      # ./modules/librewolf
    ];

  environment.pathsToLink = [
    "/share/applications"
    "/share/xdg-desktop-portal"
  ];

  nix.settings = {
    experimental-features = "nix-command flakes";
    max-jobs = 6;
    download-buffer-size = 524288000;
  };
  security.polkit.enable = true;
  # services.polkit-gnome-authentication-agent.enable = true;

  # nix.settings = {
  #   substituters = [ "https://claude-code.cachix.org" ];
  #   trusted-public-keys = [ "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk=" ];
  # };
  # nixpkgs.overlays = [ inputs.claude-code.overlays.default ];

  # TEMPORAIRE
  nixpkgs.config.allowUnfree = true;
  
  networking.networkmanager.enable = true;

  # hardware.cpu.intel.updateMicrocode = true;
  # hardware.firmware = [ pkgs.linux-firmware ];

  networking.hostId = "c1ae84e2";
  # networking.firewall.enable = false;

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  # Set your time zone.
  time.timeZone = "Europe/Paris";
  # time.timeZone = "Asia/Bangkok";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  environment.systemPackages = packages.all;

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) (map (p: lib.getName p) packages.unfree);

  # Fonts
  fonts.packages = with pkgs; [
    # Nerd fonts
    # nerdfonts
    nerd-fonts.droid-sans-mono
    meslo-lgs-nf
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs.mtr.enable = true;

  services.ratbagd.enable = true;

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?
}

