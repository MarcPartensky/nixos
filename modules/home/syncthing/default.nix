# Module home-manager : Syncthing de marc (tower, laptop, deck, Mac).
#
# Le même fichier est importé par users/marc/home.nix (Linux, partagé par
# tower/laptop/deck) et par users/mac/home.nix (Mac, via nix-darwin). La liste
# des pairs, le dossier partagé et le durcissement réseau viennent de
# services/syncthing/{mesh,settings}.nix.
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
        # `options` (pluriel) est la clé attendue par le module home-manager,
        # qui fait PUT /rest/config/options. `option` (singulier) n'existe pas
        # côté API : Syncthing répond 404/405 et le réglage est perdu.
        options = fleet.options;
        devices = fleet.devices;
        folders.${fleet.folderId} = fleet.folder;
      }
      // lib.optionalAttrs (!isDarwin) {
        # L'UI est derrière la ressource Pangolin syncthing.marcpartensky.com :
        # le proxy conserve le Host public, que Syncthing refuse par défaut
        # (403 « Host check error »). Sans objet sur le Mac.
        gui.insecureSkipHostCheck = true;
      };

    guiAddress = "127.0.0.1:8384";
  };
}
