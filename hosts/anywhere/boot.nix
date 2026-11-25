{
  services.qemuGuest.enable = true;

  boot.kernelParams = [
    "console=ttyS0"
    "boot.shell_on_fail"  # opens a shell if init fails
  ];

  boot.loader.grub = {
    enable = true;
    efiSupport = false;  # BIOS-only
    # device = "/dev/vda"; # grug doesn't want a device if disko manages the partitions
  };

  # Generate a random or fixed hostId
  networking.hostId = "a1234e5e"; # 8 hexadecimal characters

  # boot.supportedFilesystems = [ "zfs" "ext4" ];
  # boot.initrd.supportedFilesystems = [ "zfs" "ext4" ];
  boot.supportedFilesystems = [ "ext4" ];
  boot.initrd.supportedFilesystems = [ "ext4" ];
  # boot.supportedFilesystems = [ "ext4" ];
}
