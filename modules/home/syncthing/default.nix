# home-manager module: Marc's Syncthing (tower, laptop, deck, Mac).
#
# The same file is imported by users/marc/home.nix (Linux, shared by
# tower/laptop/deck) and by users/mac/home.nix (Mac, via nix-darwin). The list
# of peers, the shared folders and the network hardening come from
# services/syncthing/{mesh,settings}.nix ; settings.nix keeps only the
# folders that have a path for the current OS (the Mac does not have the photos).
{
  pkgs,
  lib,
  ...
}: let
  isDarwin = pkgs.stdenv.isDarwin;

  fleet = import ../../../services/syncthing/settings.nix {
    inherit lib isDarwin;
  };
in {
  services.syncthing = {
    enable = true;

    settings =
      {
        # `options` (plural) is the key expected by the home-manager module,
        # which does PUT /rest/config/options. `option` (singular) does not exist
        # on the API side: Syncthing answers 404/405 and the setting is lost.
        options = fleet.options;
        devices = fleet.devices;
        folders = fleet.folders;
      }
      // lib.optionalAttrs (!isDarwin) {
        # The UI is behind the Pangolin resource syncthing.marcpartensky.com:
        # the proxy keeps the public Host, which Syncthing refuses by default
        # (403 "Host check error"). Not relevant on the Mac.
        gui.insecureSkipHostCheck = true;
      };

    guiAddress = "127.0.0.1:8384";
  };
}
