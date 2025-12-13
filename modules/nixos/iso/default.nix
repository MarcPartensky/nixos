{ pkgs, modulesPath, ...} : {
  isoImage.squashfsCompression = "gzip -Xcompression-level 1";
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
}
