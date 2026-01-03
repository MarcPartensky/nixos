{ config, pkgs, ... }:

{
  # Assure-toi que Tor Browser est installé
  home.packages = [ pkgs.tor-browser ];

  # Création forcée du fichier de politique
  home.file.".tor-browser/app/distribution/policies.json".text = builtins.toJSON {
    policies = {
      ExtensionSettings = {
        "uBlock0@raymondhill.net" = {
          installation_mode = "force_installed";
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
        };
      };
      # Optionnel : Empêcher la désactivation de l'extension
      DisableAppUpdate = true;
    };
  };
}
