{ inputs, pkgs, lib, ... }:

let
  firefoxAddons = pkgs.nur.repos.rycee.firefox-addons;

  extensionList = with firefoxAddons; [
    darkreader
    ublock-origin
    bitwarden
    tabliss
    umatrix
    refined-github
    single-file
    videospeed
    sponsorblock
    return-youtube-dislikes
    privacy-badger
    tab-stash
    youtube-shorts-block
    about-sync
    auto-tab-discard
    catppuccin-mocha-mauve
    clearurls
    container-colors
    don-t-fuck-with-paste
    export-tabs-urls-and-titles
    enhanced-github
    floccus
    linkwarden
    pwas-for-firefox
    pywalfox
    session-sync
    spoof-timezone
    tab-counter-plus
    tab-session-manager
    youtube-high-definition
    proton-pass
  ];

  makeExtensionPolicy = addon: {
    name = addon.addonId;
    value = {
      installation_mode = "force_installed";
      install_url = "file://${addon}/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${addon.addonId}.xpi";
    };
  };

  prefs = {
    # Configuration des telechargements
    "browser.download.dir" = "/home/marc/downloads";
    "browser.download.folderList" = 2;
    "browser.download.useDownloadDir" = true;
    "browser.download.manager.showWhenStarting" = false;
    "browser.helperApps.alwaysAsk.force" = false;

    # Confidentialite (Hardening LibreWolf/Arkenfox)
    "privacy.resistFingerprinting" = true;
    "privacy.trackingprotection.enabled" = true;
    "privacy.trackingprotection.fingerprinting.enabled" = true;
    "privacy.trackingprotection.cryptomining.enabled" = true;
    "network.cookie.cookieBehavior" = 1;
    "privacy.sanitize.sanitizeOnShutdown" = true;
    "privacy.clearOnShutdown.cookies" = true;
    "privacy.clearOnShutdown.history" = true;
    "network.http.referer.XOriginPolicy" = 2;
    "network.dns.disablePrefetch" = true;
    "network.prefetch-next" = false;
    "dom.event.clipboardevents.enabled" = false;

    # Telemetrie et services inutiles
    "browser.newtabpage.activity-stream.feeds.telemetry" = false;
    "browser.ping-centre.telemetry" = false;
    "extensions.pocket.enabled" = false;
    "toolkit.telemetry.enabled" = false;
    "toolkit.telemetry.unified" = false;

    # Interface et divers
    "extensions.autoDisableScopes" = 0;
    "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
    "browser.startup.homepage" = "https://duckduckgo.com";
  };

in {
  nixpkgs.overlays = [ inputs.nur.overlays.default ];

  home.packages = [
    (pkgs.wrapFirefox
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.zen-browser-unwrapped
      {
        extraPolicies = {
          DisableTelemetry = true;
          DisableFirefoxAccounts = false;
          ExtensionSettings = builtins.listToAttrs (map makeExtensionPolicy extensionList);
          Extensions = {
            Locked = [
              "uBlock0@raymondhill.net"
              "446900e4-71c2-419f-a6a7-df9c091e268b"
            ];
          };
          SearchEngines = {
            Default = "ddg";
            Add = [
              {
                Name = "nixpkgs packages";
                URLTemplate = "https://search.nixos.org/packages?query={searchTerms}";
                IconURL = "https://wiki.nixos.org/favicon.ico";
                Alias = "@np";
              }
            ];
          };
        };

        extraPrefs = lib.concatLines (
          lib.mapAttrsToList (
            name: value: ''lockPref(${lib.strings.toJSON name}, ${lib.strings.toJSON value});''
          ) prefs
        );
      }
    )
  ];
}
