{ pkgs, ... }:
{
  users.users.marc.extraGroups = [ "docker" ];
  environment.etc."resolv.conf".text = "nameserver 8.8.8.8\n";

  virtualisation = {
    containers.enable = true;

    docker = {
      storageDriver = "zfs";
      enable = true;
      daemon.settings = {
        dns = [ "1.1.1.1" "8.8.8.8" ];
      #   registry-mirrors = [ "https://mirror.gcr.io" ];
      #  "default-address-pools" = [
      #     { "base" = "172.27.0.0/16"; "size" = 24; }
      #   ];
      };

      # enable = true;
      rootless = {
          enable = false;
          # setSocketVariable = true;
      };

      # # Required for containers under podman-compose to be able to talk to each other.
      # defaultNetwork.settings.dns_enabled = true;
    };
  };

  # Useful other development tools
  environment.systemPackages = with pkgs; [
    dive # look into docker image layers
    # podman-tui # status of containers in the terminal
    docker-compose # start group of containers for dev
    #podman-compose # start group of containers for dev
  ];
}

