# winnie dev server (Vite + HMR), target of the newt resource `winnie-dev`
# (dev.winnie.marcpartensky.com -> 127.0.0.1:8080, see services/newt).
#
# As a system service and not launched by hand: an `npm run dev` in a shell
# died on every user session restart (every `nixos-rebuild
# switch` starts one) and the domain fell back to 502 until someone
# relaunched it. Here the service restarts on its own and survives switches.
{ pkgs, ... }:
let
  # Slim 22: no npm, we launch vite's entry point directly with node,
  # it is the exact equivalent of `npm run dev` (the script is just `vite`).
  # Same version as the one verified by hand (22.23.3).
  node = pkgs.nodejs-slim_22;
in {
  systemd.services.winnie-dev = {
    description = "Winnie dev server (Svelte/Vite HMR) on 127.0.0.1:8080";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      User = "marc";
      Group = "users";
      WorkingDirectory = "/home/marc/git/winnie/app";
      # vite.config.ts already does host:true (LAN) + allowedHosts for the public
      # domain + strictPort on 8080: nothing to pass as an argument.
      ExecStart = "${node}/bin/node /home/marc/git/winnie/app/node_modules/vite/bin/vite.js";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
