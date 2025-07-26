{ pkgs, lib, ... }:
{

  imports = [
    ./profiles/youtube.nix
  ];
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
      profiles.default = {
         id = 0;
         # extensions = []
         name = "Default";
         search = {
           force = true;
           default = "Startpage";
           engines = {
             "Startpage" = {
               urls = [{ template = "https://www.startpage.com/rvd/search?query={searchTerms}&language=auto"; }];
               icon = "https://www.startpage.com/sp/cdn/favicons/mobile/android-icon-192x192.png";
               updateInterval = 24 * 60 * 60 * 1000; # every day
               definedAliases = [ "@s" ];
             };
           };
         };
         # settings = {
         #    "extensions.activeThemeID" = "firefox-compact-dark@mozilla.org";

         #    # For Firefox GNOME theme:
         #    "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
         #    "browser.tabs.drawInTitlebar" = true;
         #    "svg.context-properties.content.enabled" = true;
         # };
         # userChrome = ''
         #    @import "firefox-gnome-theme/userChrome.css";
         #    @import "firefox-gnome-theme/theme/colors/dark.css"; 
         # '';
      };
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
            (extension "darkreader" "addon@darkreader.org")
            (extension "ublock-origin" "uBlock0@raymondhill.net")
            (extension "bitwarden-password-manager" "{446900e4-71c2-419f-a6a7-df9c091e268b}")
            (extension "tabliss" "extension@tabliss.io")
            (extension "umatrix" "uMatrix@raymondhill.net")
            (extension "catppuccin-mocha-lavender-git" "{8446b178-c865-4f5c-8ccc-1d7887811ae3}")
            (extension "refined_github" "{a4c4eda4-fb84-4a84-b4a1-f7c1cbf2a1ad}")
            (extension "single-file" "{531906d3-e22f-4a6c-a102-8057b88a1a63}")
            (extension "videospeed" "{7be2ba16-0f1e-4d93-9ebc-5164397477a9}")
            (extension "sponsorblock" "sponsorBlocker@ajay.app")
            (extension "watch_later_youtube_shortcut" "WatchLaterShortcutforYouTube@worlthirteen.me")
            (extension "youtube_anti_translate" "{458160b9-32eb-4f4c-87d1-89ad3bdeb9dc}")
            (extension "return_youtube_dislikes" "{762f9885-5a13-4abd-9c77-433dcd38b8fd}")

            (extension "tab_stash" "tab-stash@condordes.net")
            (extension "pwas_for_firefox" "firefoxpwa@filips.si")
            (extension "privacy_badger17" "jid1-MnnxcxisBPnSXQ@jetpack")
          ];
          # To add additional extensions, find it on addons.mozilla.org, find
          # the short ID in the url (like https://addons.mozilla.org/en-US/firefox/addon/!SHORT_ID!/)
          # Then, download the XPI by filling it in to the install_url template, unzip it,
          # run `jq .browser_specific_settings.gecko.id manifest.json` or
          # `jq .applications.gecko.id manifest.json` to get the UUID
        "3rdparty".Extensions = {
		  # https://github.com/gorhill/uBlock/blob/master/platform/common/managed_storage.json
		  "uBlock0@raymondhill.net".adminSettings = {
		  	userSettings = rec {
		  	  uiTheme = "dark";
		  	  uiAccentCustom = true;
		  	  uiAccentCustom0 = "#8300ff";
		  	  # cloudStorageEnabled = mkForce false; # Security liability?
		  	  importedLists = [
		  	    "https://filters.adtidy.org/extension/ublock/filters/3.txt"
		  	    "https://github.com/DandelionSprout/adfilt/raw/master/LegitimateURLShortener.txt"
		  	  ];
		  	  externalLists = lib.concatStringsSep "\n" importedLists;
		  	};
		  	selectedFilterLists = [
		  	  "CZE-0"
		  	  "adguard-generic"
		  	  "adguard-annoyance"
		  	  "adguard-social"
		  	  "adguard-spyware-url"
		  	  "easylist"
		  	  "easyprivacy"
		  	  "https://github.com/DandelionSprout/adfilt/raw/master/LegitimateURLShortener.txt"
		  	  "plowe-0"
		  	  "ublock-abuse"
		  	  "ublock-badware"
		  	  "ublock-filters"
		  	  "ublock-privacy"
		  	  "ublock-quick-fixes"
		  	  "ublock-unbreak"
		  	  "urlhaus-1"
		  	];
		  };
		};
        Bookmarks = [
          {
            "Title" = "";
            "URL" = "https://youtube.com";
            "Placement" = "toolbar";
          }
          {
            "Title" = "";
            "URL" = "https://music.youtube.com";
            "Placement" = "toolbar";
          }
          {
            "Title" = "";
            "URL" = "https://search.nixos.org/packages";
            "Placement" = "toolbar";
          }
          {
            "Title" = "";
            "URL" = "https://chat.deepseek.com";
            "Placement" = "toolbar";
          }
          {
            "Title" = "";
            "URL" = "https://cloud.marcpartensky.com/apps/deck";
            "Placement" = "toolbar";
          }
          {
            "Title" = "";
            "URL" = "https://messenger.com";
            "Placement" = "toolbar";
          }
          {
            "Title" = "";
            "URL" = "https://web.whatsapp.com";
            "Placement" = "toolbar";
          }
        ];
      };
    };
  };
}
