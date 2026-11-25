{ config, pkgs, ... }:

{
  # Make sure Tor Browser is installed
  home.packages = [ pkgs.tor-browser ];

  # Forced creation of the policy file
  home.file.".tor-browser/app/distribution/policies.json".text = builtins.toJSON {
    policies = {
      ExtensionSettings = {
        "uBlock0@raymondhill.net" = {
          installation_mode = "force_installed";
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
        };
      };
      # Optional: Prevent disabling the extension
      DisableAppUpdate = true;
    };
  };
}
