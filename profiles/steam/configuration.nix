{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
  ];

  networking.firewall = {
    enable = true;
  };

  specialisation.gamescope.configuration = {
    imports = [../../modules/nixos/jovian];
  };

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;
}
