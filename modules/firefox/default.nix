{ pkgs, lib, inputs, ... }:

{
  nixpkgs.overlays = [ inputs.nur.overlays.default ];

  home-manager.users.marc = { pkgs, inputs, ... }:

  let
    # nur = inputs.nur.packages.${pkgs.system};
    firefoxAddons = pkgs.nur.repos.rycee.firefox-addons;

    # Extensions from NUR or directly from pkgs
    extensions = with firefoxAddons; [
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
      refined-github
      session-sync
      spoof-timezone
      tab-counter-plus
      tab-session-manager
      youtube-high-definition
      proton-pass
      # wallabagger
      # ghostery
      # firefoxpwa
    ];
  in
  {
    xdg.desktopEntries = {
        # "default" = {
        #     name = "Perso";
        #     exec = "${pkgs.firefox}/bin/firefox -P Default -no-remote %u";
        #     terminal = false;
        #     type = "Application";
        #     icon = "firefox";
        # };
        # "youtube" = {
        #     name = "Youtube";
        #     exec = "${pkgs.firefox}/bin/firefox -P Youtube -no-remote %u";
        #     terminal = false;
        #     type = "Application";
        #     icon = "firefox";
        # };
        "firefox-work" = {
            name = "Firefox Work";
            exec = "${pkgs.firefox}/bin/firefox -P Work -no-remote %u";
            terminal = false;
            type = "Application";
            icon = "firefox";
        };
    };

    nixpkgs.overlays = [ inputs.nur.overlays.default ];
    programs.firefox = {
      enable = true;
      package = pkgs.firefox;
      # nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];

      policies = {
        Extensions = {
          Locked = [
            # enable both extensions
            "uBlock0@raymondhill.net"
            "446900e4-71c2-419f-a6a7-df9c091e268b" # Extension ID for bitwarden
          ];
        };
        ExtensionSettings = {
            "uBlock0@raymondhill.net" = { default_area = "menupanel"; };
            "446900e4-71c2-419f-a6a7-df9c091e268b" = { default_area = "navbar"; };
            "umatrix@raymondhill.net" = {
              default_area = "menupanel";
              filters = [
                "EasyList"
                "EasyPrivacy"
                "Fanboy's Social Blocking List"
                "uMatrix Filters"
              ];
            };
        };
      };

      profiles = {
        default = {
          name = "Default";
          path = "default";
          isDefault = true;
          id = 0;

          extensions = {
            packages = extensions;
          };

          search = {
            force = true;
            default = "Startpage";
            engines = {
              "Startpage" = {
                urls = [{
                  template = "https://www.startpage.com/rvd/search?query={searchTerms}&language=auto";
                }];
                icon = "https://www.startpage.com/sp/cdn/favicons/mobile/android-icon-192x192.png";
                updateInterval = 86400000;
                definedAliases = [ "@s" ];
              };
            };
          };

          settings = {
            "extensions.autoDisableScopes" = 0;
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
            "svg.context-properties.content.enabled" = true;
          };

        };

        youtube = {
          name = "Youtube";
          path = "youtube";
          id = 1;
          # bookmarks = { 
          #   force = true;
          #   bookmarks = [
          #     {
          #       name = "Youtube";
          #       url = "https://youtube.com";
          #     }
          #   ];
          #   settings = {
          #     
          #   };
          # };

          extensions = {
            packages = extensions;
          };

          settings = {
            "browser.newtabpage.activity-stream.feeds.section.highlights" = false;
            "browser.startup.homepage" = "https://youtube.com";
            "extensions.autoDisableScopes" = 0;
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
            "svg.context-properties.content.enabled" = true;
          };

          # userChrome = ''
          #   @import "${whiteSurTheme}/chrome/userChrome.css";
          # '';
        };

        work = {
          name = "Work";
          path = "work";
          id = 2;

          extensions = {
            packages = extensions;
          };

          settings = {
            "browser.startup.homepage" =
            "https://cloud.marcpartensky.com/apps/deck/board/2";
            "extensions.autoDisableScopes" = 0;
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
            "svg.context-properties.content.enabled" = true;
            "network.cookie.cookieBehavior" = 0; # Enable all cookies (Accept All Cookies)
            "network.cookie.lifetimePolicy" = 2; # Retain cookies until they expire (persistent)
            "privacy.clearOnShutdown.cookies" = false; # Do not clear cookies on shutdown
          };

          # userChrome = ''
          #   @import "${whiteSurTheme}/chrome/userChrome.css";
          # '';
        };
      };
    };
    # home.file.".mozilla/firefox/profile.default/chrome/userChrome.css".source = ./path/to/userChrome.css;
  };
}
