{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops.nixosModules.sops
    ../../users.nix
    ../../hosts/deck/disko.nix
    ../../hosts/deck/hardware-configuration.nix
    ../../modules/nixos/networking
    ../../modules/nixos/pipewire
    ../../modules/nixos/xdg
    ../../modules/nixos/jovian
  ];

  jovian.devices.steamdeck.enable = true;

  services.desktopManager.plasma6.enable = true;
  jovian.steam.desktopSession = lib.mkForce "plasma";

  security.rtkit.enable = true; # était fourni par ton module bluetooth

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  nix.settings.experimental-features = "nix-command flakes";
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  nixpkgs.config.allowUnfree = true;
  sops.defaultSopsFile = ../../secrets/common.yml;

  programs.zsh.enable = true; # requis par users.nix
  services.openssh.enable = true;
  services.automatic-timezoned.enable = true;

  environment.systemPackages = with pkgs; [git neovim htop];

  networking.hostName = "deck";
  system.stateVersion = "26.05";
}
