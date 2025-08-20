{ config, pkgs, inputs, ... }:
{
  home-manager.users.marc = { pkgs, inputs, ... }:
  let
    # Define the flavor (mocha, macchiato, frappe, latte)
    flavor = "mocha";
  in {
    # Enable Thunderbird
    programs.thunderbird = {
      enable = true;
      profiles.default = {
        isDefault = true;
        # Install the Catppuccin theme
        settings = {
          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        };
        userChrome = ''
          @import "${inputs.catppuccin-thunderbird}/src/${flavor}/userChrome.css";
        '';
        userContent = ''
          @import "${inputs.catppuccin-thunderbird}/src/${flavor}/userContent.css";
        '';
      };
    };
  
    # Optional: Ensure the theme directory exists
    home.file.".thunderbird/catppuccin".source = "${inputs.catppuccin-thunderbird}/src";
  };
}
