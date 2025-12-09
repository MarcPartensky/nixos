{
  disko.devices = {
    disk = {
      root = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "nofail" ];
              };
            };
            swap = {
              # name = "swap";
              # type = "8200";       # Linux swap
              size = "16G";
              content = {
                type = "swap";
                randomEncryption = true;
                priority = 100;
              };
            };
            zfs = {
              size = "1024G";
              content = {
                type = "zfs";
                pool = "nixos";
              };
            };
          };
        };
      };
    };
    zpool = {
      nixos = {
        type = "zpool";
        rootFsOptions = {
          mountpoint = "none";
          compression = "lz4";
          acltype = "posixacl";
          xattr = "sa";
          "com.sun:auto-snapshot" = "true";
        };
        options.ashift = "12";
        datasets = {
          "root" = {
            type = "zfs_fs";
            options = {
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              #keylocation = "file:///tmp/secret.key";
              keylocation = "prompt";
            };
            mountpoint = "/";

          };
          "nix" = {
            type = "zfs_fs";
            options.mountpoint = "/nix";
            mountpoint = "/nix";
          };
          "marc" = {
            type = "zfs_fs";
            options.mountpoint = none;
          };
          "marc/data" = {
            type = "zfs_fs";
            options.mountpoint = "/home/marc";
          };
          "marc/media" = {
            type = "zfs_fs";
            options.mountpoint = "/home/marc/media";
          };
          "marc/downloads" = {
            type = "zfs_fs";
            options.mountpoint = "/home/marc/Downloads";
          };
          "marc/syncthing" = {
            type = "zfs_fs";
            options.mountpoint = "/home/marc/syncthing";
          };

          # # README MORE: https://wiki.archlinux.org/title/ZFS#Swap_volume
          # "root/swap" = {
          #   type = "zfs_volume";
          #   size = "16G";
          #   content = {
          #     type = "swap";
          #   };
          #   options = {
          #     volblocksize = "4096";
          #     compression = "zle";
          #     logbias = "throughput";
          #     sync = "always";
          #     primarycache = "metadata";
          #     secondarycache = "none";
          #     "com.sun:auto-snapshot" = "false";
          #   };
          # };
        };
      };
    };
  };
}
