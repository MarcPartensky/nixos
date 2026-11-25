# Dev VM "dev": `just vm` (or `nix run .#dev`).
#
# To create another VM:
#   1. cp vms/dev.nix vms/app2.nix, change networking.hostName (and the ports)
#   2. flake.nix: duplicate the nixosConfigurations.dev block into .app2, and
#      packages.x86_64-linux.app2 = self.nixosConfigurations.app2.config.microvm.declaredRunner;
#   3. just vm app2
{
  lib,
  pkgs,
  ...
}: {
  imports = [./default.nix];

  networking.hostName = "dev";

  microvm = {
    # tower: 16 cores / 62 GB but a heavily loaded machine, stay reasonable.
    vcpu = 6;
    mem = 6144;

    # Host code visible in the VM, read/write (9p). The mount
    # is at marc's uid (1000 = the same as in the VM), so the files
    # stay his. Reduce to a specific project if needed.
    shares = [
      {
        tag = "git";
        source = "/home/marc/git";
        mountPoint = "/mnt/host/git";
        proto = "9p";
      }
    ];

    # Dev ports: the server launched INSIDE the VM is reachable from tower.
    # Shifted by +10000 to avoid conflicting with a tower service
    # (3000 = gitea for ex.): qemu refuses to start if the host port is already
    # taken. Here: VM:3000 -> tower:13000, VM:5173 -> tower:15173, etc.
    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 13000;
        guest.port = 3000;
      } # node/next
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 14000;
        guest.port = 4000;
      } # phoenix
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 15173;
        guest.port = 5173;
      } # vite
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 18000;
        guest.port = 8000;
      } # django/fastapi
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 18080;
        guest.port = 8080;
      } # misc
    ];
  };

  # Packages specific to this VM (the base is in vms/default.nix):
  # environment.systemPackages = with pkgs; [python3 postgresql];
}
