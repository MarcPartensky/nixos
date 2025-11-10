{ lib, ... }:

{
  # services.qemuGuest.enable = true;
  # # boot.loader.grub.device = "/dev/vda"; # adapte si ton disque est vda/sda/nvme0n1
  # boot.kernelParams = [
  #   "console=ttyS0"
  #   "boot.shell_on_fail"  # ouvre un shell si l’init échoue
  # ];

  # boot.loader.grub = {
  #   enable = true;
  #   efiSupport = false;
  #   # device = "/dev/vda";     # no need to set devices, disko will add all devices that have a EF02 partition to the list already
  # };

  # boot.supportedFilesystems = [ "ext4" ];

  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/vda";
        content = {
          type = "gpt";
          # efiGptPartitionFirst = false;
          partitions = {
            # ESP = {
            #   type = "EF00";
            #   size = "512M";
            #   content = {
            #     type = "filesystem";
            #     format = "vfat";
            #     mountpoint = "/boot";
            #     mountOptions = [ "umask=0077" ];
            #   };
            # };
            bios = {
              name = "bios";
              size = "1M";
              type = "EF02";  # BIOS boot partition
            };
            lvm = {
              name = "lvm";
              label = "disk-main-lvm";
              size = "100%";
              content = {
                type = "lvm_pv";
                vg = "vg0";
              };
            };
          };
        };
      };
    };
    lvm_vg = {
      vg0 = {
        type = "lvm_vg";
        lvs = {
          # la swap avant root
          swap = {
            size = "4G";
            content = { type = "swap"; };
          };
          root = {
            size = "100%FREE";  # prend tout l'espace disponible
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "defaults" ];
            };
          };
          # home = {
          #   size = "10G";
          #   content = {
          #     type = "filesystem";
          #     format = "ext4";
          #     mountpoint = "/home";
          #   };
          # };
        };
      };
    };
  };
}

