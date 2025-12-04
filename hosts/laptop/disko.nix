{
  disko.devices = {
    disk.main = {
      device = "/dev/nvme0n1";
      type = "disk";

      content = {
        type = "gpt";
        partitions = {
          # BIOS boot (inutile sur UEFI mais ça ne gêne pas)
          bios = {
            type = "EF02";
            size = "1M";
          };

          # /boot EFI
          esp = {
            type = "EF00";
            size = "512M";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };

          # bpool ZFS (boot pool)
          bpool = {
            size = "1G";
            content = {
              type = "zfs";
              pool = "bpool";
            };
          };

          # rpool = 50% du disque total
          rpool = {
            size = "50%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };

          # 🎉 Le reste du disque (~50%) est libéré et reste *non partitionné*
        };
      };
    };

    # ZFS pools definition
    zpool = {
      bpool = {
        type = "zpool";
        options = {
          ashift = "12";
          compatibility = "grub2";
        };
        rootFsOptions = {
          compression = "lz4";
        };
        datasets = {
          "boot" = {
            mountpoint = "/boot";
            options.mountpoint = "legacy";
          };
        };
      };

      rpool = {
        type = "zpool";
        options = { ashift = "12"; };
        rootFsOptions = {
          compression = "zstd";
          atime = "off";
          xattr = "sa";
          mountpoint = "none";
        };

        datasets = {
          "root" = {
            mountpoint = "/";
            options.mountpoint = "legacy";
          };

          "home" = {
            mountpoint = "/home";
            options.mountpoint = "legacy";
          };

          "store" = {
            mountpoint = "/nix/store";
            options.mountpoint = "legacy";
          };
        };
      };
    };
  };
}

