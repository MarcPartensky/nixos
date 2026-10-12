# VM de dev « dev » : `just vm` (ou `nix run .#dev`).
#
# Pour créer une autre VM :
#   1. cp vms/dev.nix vms/app2.nix, changer networking.hostName (et les ports)
#   2. flake.nix : dupliquer le bloc nixosConfigurations.dev en .app2, et
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
    # tower : 16 cœurs / 62 Go mais machine bien chargée, rester raisonnable.
    vcpu = 6;
    mem = 6144;

    # Code de l'hôte visible dans la VM, en lecture/écriture (9p). Le montage
    # est à l'uid de marc (1000 = le même que dans la VM), donc les fichiers
    # restent à lui. Réduire à un projet précis si besoin.
    shares = [
      {
        tag = "git";
        source = "/home/marc/git";
        mountPoint = "/mnt/host/git";
        proto = "9p";
      }
    ];

    # Ports de dev : le serveur lancé DANS la VM est joignable depuis tower.
    # Décalés de +10000 pour ne pas entrer en conflit avec un service de tower
    # (3000 = gitea par ex.) : qemu refuse de démarrer si le port hôte est déjà
    # pris. Ici : VM:3000 -> tower:13000, VM:5173 -> tower:15173, etc.
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
      } # divers
    ];
  };

  # Paquets propres à cette VM (la base est dans vms/default.nix) :
  # environment.systemPackages = with pkgs; [python3 postgresql];
}
