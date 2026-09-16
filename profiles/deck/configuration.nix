{lib, ...}: {
  imports = [
    ../../hosts/deck/disko.nix
    ../../hosts/deck/hardware-configuration.nix
    ../../modules/nixos/jovian
  ];

  jovian.devices.steamdeck.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "deck";
  system.stateVersion = lib.mkForce "26.05"; # install neuve
}
