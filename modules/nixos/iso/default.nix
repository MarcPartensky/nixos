{
  lib,
  modulesPath,
  ...
}: {
  isoImage.squashfsCompression = "gzip -Xcompression-level 1";
  imports = [(modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")];
  boot.kernel.sysctl."vm.overcommit_memory" = lib.mkForce "1";
}
