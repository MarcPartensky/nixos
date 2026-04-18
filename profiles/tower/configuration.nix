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

  # sops.defaultSopsFile = ../../secrets/tower.yml;
}
