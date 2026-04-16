{
  lib,
  pkgs,
  inputs,
  ...
}: {
  modules = [
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
  ];
}
