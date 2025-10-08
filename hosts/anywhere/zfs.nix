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
            # Partition BIOS pour GRUB
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
            size = "10G"; # taille de / en ext4
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
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
        mode = ""; # ou "mirror", "raidz1" si plusieurs disques
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
