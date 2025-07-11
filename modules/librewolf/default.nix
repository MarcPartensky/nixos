{ pkgs, ... }:
{

  home-manager.users.marc = { pkgs, inputs, ... }:
  
  let
    # Fetch the WhiteSur theme (replace REV and SHA256 with latest from GitHub)
    whiteSurTheme = pkgs.fetchFromGitHub {
      owner = "rashadgasimli";
      repo = "WhiteSur-librewolf-theme";
      rev = "110470bdec93e2525df1e54f8b0916a00d83f34c"; # Check latest commit
      sha256 = "sha256-lo9/YURgyt/SXVNwgZndn9HA5FCqquTMAwPY8Shxhss="; # Use nix-prefetch-github
    };
  in {

    # Deploy theme files to LibreWolf's chrome directory
    # home.file.".librewolf/chrome".source = "${whiteSurTheme}/chrome";
    # programs.firefox = {
    #   nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];
    # };

    # home.file."firefox-gnome-theme" = {
    #     target = ".mozilla/firefox/default/chrome/firefox-gnome-theme";
    #     source = (fetchTarball "https://github.com/rashadgasimli/WhiteSur-librewolf-theme/archive/refs/tags/2023-10-30.tar.gz");
    # };
      # Enable required preferences in user.js
    # home.file.".librewolf/profiles.ini".text = ''
    #   [General]
    #   StartWithLastProfile=1
    #   [Profile0]
    #   Name=default
    #   IsRelative=1
    #   Path=default/
    #   Default=1
    # '';

    # home.file.".librewolf/default/user.js".text = ''
    #   // Enable userChrome.css
    #   user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
    #   // Required for SVG icons
    #   user_pref("svg.context-properties.content.enabled", true);
    # '';

    programs.firefox = {
      enable = true;
      package = pkgs.librewolf;
      nativeMessagingHosts= [ pkgs.firefoxpwa ];
      # profiles.default = {
      #    name = "Default";
      #    settings = {
      #       "extensions.activeThemeID" = "firefox-compact-dark@mozilla.org";

      #       # For Firefox GNOME theme:
      #       "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
      #       "browser.tabs.drawInTitlebar" = true;
      #       "svg.context-properties.content.enabled" = true;
      #    };
      #    userChrome = ''
      #       @import "firefox-gnome-theme/userChrome.css";
      #       @import "firefox-gnome-theme/theme/colors/dark.css"; 
      #    '';
      # };
      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        Preferences = {
          "cookiebanners.service.mode.privateBrowsing" = 2; # Block cookie banners in private browsing
          "cookiebanners.service.mode" = 2; # Block cookie banners
          "privacy.donottrackheader.enabled" = true;
          "privacy.fingerprintingProtection" = true;
          "privacy.resistFingerprinting" = true;
          "privacy.trackingprotection.emailtracking.enabled" = true;
          "privacy.trackingprotection.enabled" = true;
          "privacy.trackingprotection.fingerprinting.enabled" = true;
          "privacy.trackingprotection.socialtracking.enabled" = true;
        };
        ExtensionSettings = with builtins;
          let extension = shortId: uuid: {
            name = uuid;
            value = {
              install_url = "https://addons.mozilla.org/en-US/firefox/downloads/latest/${shortId}/latest.xpi";
              installation_mode = "normal_installed";
            };
          };
          in listToAttrs [
            # (extension "tree-style-tab" "treestyletab@piro.sakura.ne.jp")
            (extension "ublock-origin" "uBlock0@raymondhill.net")
            (extension "bitwarden-password-manager" "{446900e4-71c2-419f-a6a7-df9c091e268b}")
            (extension "tabliss" "extension@tabliss.io")
            (extension "umatrix" "uMatrix@raymondhill.net")
            (extension "refined_github" "sindresorhus@gmail.com")
            (extension "videospeed" "codebicycle@gmail.com")
            (extension "sponsorblock" "dev@ajay.app")
            (extension "pwas_for_firefox" "projects@filips.si")
            # (extension "libredirect" "7esoorv3@alefvanoon.anonaddy.me")
             #(extension "clearurls" "{74145f27-f039-47ce-a470-a662b129930a}")
          ];
          # To add additional extensions, find it on addons.mozilla.org, find
          # the short ID in the url (like https://addons.mozilla.org/en-US/firefox/addon/!SHORT_ID!/)
          # Then, download the XPI by filling it in to the install_url template, unzip it,
          # run `jq .browser_specific_settings.gecko.id manifest.json` or
          # `jq .applications.gecko.id manifest.json` to get the UUID
      };
    };
  };
}
