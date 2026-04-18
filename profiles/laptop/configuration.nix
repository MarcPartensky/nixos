{inputs, ...}: {
  imports = [
    ../../hosts/laptop/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
  ];

  # sops.defaultSopsFile = ../../secrets/laptop.yml;
}
