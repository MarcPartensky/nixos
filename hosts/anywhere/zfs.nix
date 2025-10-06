{ lib, ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/vda";
        content = {
          type = "gpt";
          partitions = {
            # Partition BIOS pour GRUB
            bios = {
              name = "bios";
              size = "1M";
              type = "EF02"; # BIOS boot
            };

            # Partition ZFS pour le pool
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool"; # nom du pool ZFS
              };
            };
          };
        };
      };
    };

    # Définition du pool ZFS
    zpool = {
      rpool = {
        type = "zpool";
        mode = "mirror"; # ou "mirror", "raidz1" si plusieurs disques
        options.cachefile = "none";
        rootFsOptions = {
          compression = "lz4";
          atime = "off";
          xattr = "sa";
        };
        mountpoint = "/";

        datasets = {
          # root dataset
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options.compression = "lz4";
          };

          # swap dataset (optionnel)
          # swap = {
          #   type = "zfs_volume";
          #   size = "4G";
          #   content = {
          #     type = "swap";
          #   };
          # };

          # home dataset (optionnel)
          # home = {
          #   type = "zfs_fs";
          #   mountpoint = "/home";
          #   options.compression = "lz4";
          # };
        };
      };
    };
  };
}
