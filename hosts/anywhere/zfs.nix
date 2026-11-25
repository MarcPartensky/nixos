{ lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    zfs
  ];

  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/vda";
        content = {
          type = "gpt";
          partitions = {
            # BIOS partition for GRUB
            bios = {
              name = "bios";
              size = "1M";
              type = "EF02"; # BIOS boot
            };

          boot = {
            name = "boot";
            size = "512M";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/boot";
            };
          };

         root = {
            name = "root";
            size = "10G"; # size of / in ext4
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };

            # ZFS partition for the pool
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool"; # name of the ZFS pool
              };
            };
          };
        };
      };
    };

    # ZFS pool definition
    zpool = {
      rpool = {
        type = "zpool";
        mode = ""; # or "mirror", "raidz1" if several disks
        options.cachefile = "none";
        rootFsOptions = {
          mountpoint = "none";
          compression = "lz4";
          atime = "off";
          xattr = "sa";
        };
        # mountpoint = "/";

        datasets = {
          # root dataset
          home = {
            type = "zfs_fs";
            mountpoint = "/home";
            options.compression = "lz4";
          };

          # swap dataset (optional)
          # swap = {
          #   type = "zfs_volume";
          #   size = "4G";
          #   content = {
          #     type = "swap";
          #   };
          # };

          # home dataset (optional)
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
