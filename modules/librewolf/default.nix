{ pkgs, ... }:
{
  programs.firefox = {
    nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];
  };

  home-manager.users.marc = { pkgs, inputs, ... }: {
    programs.firefox = {
      enable = true;
      package = pkgs.librewolf;
      # nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];
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
