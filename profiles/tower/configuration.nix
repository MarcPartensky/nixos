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

    allowedTCPPorts = [
      8083 # Pangolin / Apps
      5432 # PostgreSQL
    ];
  };

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;
}
