# Dev server de winnie (Vite + HMR), cible de la ressource newt `winnie-dev`
# (dev.winnie.marcpartensky.com -> 127.0.0.1:8080, voir services/newt).
#
# En service systeme et non lance a la main : un `npm run dev` dans un shell
# mourait a chaque redemarrage de session utilisateur (tout `nixos-rebuild
# switch` en lance un) et le domaine retombait en 502 jusqu'a ce que quelqu'un
# le relance. Ici le service redemarre seul et survit aux switches.
{ pkgs, ... }:
let
  # Slim 22 : pas de npm, on lance l'entree de vite directement avec node,
  # c'est l'equivalent exact de `npm run dev` (le script est `vite` tout court).
  # Meme version que celle verifiee a la main (22.23.3).
  node = pkgs.nodejs-slim_22;
in {
  systemd.services.winnie-dev = {
    description = "Winnie dev server (Svelte/Vite HMR) sur 127.0.0.1:8080";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      User = "marc";
      Group = "users";
      WorkingDirectory = "/home/marc/git/winnie/app";
      # vite.config.ts fait deja host:true (LAN) + allowedHosts pour le domaine
      # public + strictPort sur 8080 : rien a passer en argument.
      ExecStart = "${node}/bin/node /home/marc/git/winnie/app/node_modules/vite/bin/vite.js";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
