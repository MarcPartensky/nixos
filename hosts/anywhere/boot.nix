{
  services.qemuGuest.enable = true;

  boot.kernelParams = [
    "console=ttyS0"
    "boot.shell_on_fail"  # ouvre un shell si l’init échoue
  ];

  boot.loader.grub = {
    enable = true;
    efiSupport = false;  # BIOS-only
    # device = "/dev/vda"; # grug veut pas de device si disko gère les partitions
  };

  # Générer un hostId aléatoire ou fixe
  networking.hostId = "a1234e5e"; # 8 caractères hexadécimaux

  boot.supportedFilesystems = [ "zfs" "ext4" ];
  boot.initrd.supportedFilesystems = [ "zfs" "ext4" ];
  # boot.supportedFilesystems = [ "ext4" ];
}
