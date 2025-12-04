{ lib, ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";   # adapte si besoin
        content = {
          type = "gpt";
          partitions = {
            bios = {
              name = "bios";
              type = "EF02";
              size = "1M";
            };

            esp = {
              name = "esp";
              type = "EF00";
              size = "512M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "fmask=0077" "dmask=0077" ];
              };
            };

            bpool = {
              name = "bpool";
              size = "1G";       # petit pool boot
              content = {
                type = "zfs";
                pool = "bpool";
              };
            };

            rpool = {
              name = "rpool";
              size = "50%";      # <<< 50% usage du disque
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };

            free = {
              name = "unused-space";
              size = "50%";      # <<< 50% laissé vide, GPT réservé
              # pas de content
            };
          };
        };
      };
    };

    zpool = {
      bpool = {
        type = "zpool";
        options = {
          ashift = "12";
          compatibility = "grub2";
          autotrim = "on";
        };
        rootFsOptions = {
          compression = "lz4";
          mountpoint = "none";
        };
        datasets = {
          boot = {
            mountpoint = "/boot";
            options.mountpoint = "legacy";
          };
        };
      };

      rpool = {
        type = "zpool";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          compression = "zstd";
          xattr = "sa";
          atime = "off";
          mountpoint = "none";
        };
        datasets = {
          root = {
            mountpoint = "/";
            options.mountpoint = "legacy";
          };
          home = {
            mountpoint = "/home";
            options.mountpoint = "legacy";
          };
          store = {
            mountpoint = "/nix/store";
            options.mountpoint = "legacy";
          };
        };
      };
    };
  };
}

