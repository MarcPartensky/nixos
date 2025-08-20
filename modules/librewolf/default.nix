{ pkgs, lib, inputs, ... }:

{
  nixpkgs.overlays = [ inputs.nur.overlays.default ];

  home-manager.users.marc = { pkgs, inputs, ... }:

  let
    # WhiteSur theme
    whiteSurTheme = pkgs.fetchFromGitHub {
      owner = "rashadgasimli";
      repo = "WhiteSur-librewolf-theme";
      rev = "110470bdec93e2525df1e54f8b0916a00d83f34c";
      sha256 = "sha256-lo9/YURgyt/SXVNwgZndn9HA5FCqquTMAwPY8Shxhss=";
    };
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
      # firefoxpwa
    ];
  in
  {
    xdg.desktopEntries = {
        "default" = {
            name = "Perso";
            exec = "${pkgs.librewolf}/bin/librewolf -P Default -no-remote %u";
            terminal = false;
            type = "Application";
            icon = "librewolf";
        };
        "youtube" = {
            name = "Youtube";
            exec = "${pkgs.librewolf}/bin/librewolf -P Youtube -no-remote %u";
            terminal = false;
            type = "Application";
            icon = "librewolf";
        };
        "work" = {
            name = "Work";
            exec = "${pkgs.librewolf}/bin/librewolf -P Work -no-remote %u";
            terminal = false;
            type = "Application";
            icon = "librewolf";
        };
    };

    nixpkgs.overlays = [ inputs.nur.overlays.default ];
    programs.librewolf = {
      enable = true;
      package = pkgs.librewolf;

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

          # userChrome = ''
          #   @import "${whiteSurTheme}/chrome/userChrome.css";
          # '';
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
          };

          # userChrome = ''
          #   @import "${whiteSurTheme}/chrome/userChrome.css";
          # '';
        };
      };
    };

    # home.file.".mozilla/firefox/profile.default/chrome/userChrome.css".source = ./path/to/userChrome.css;


    home.file = {
      ".librewolf/default/chrome" = {
        source = "${whiteSurTheme}/chrome";
        recursive = true;
      };
      ".librewolf/youtube/chrome" = {
        source = "${whiteSurTheme}/chrome";
        recursive = true;
      };
      "share/themes/WhiteSur-Dark" = {
        source = "${whiteSurTheme}/chrome";
        recursive = true;
      };
    };
  };
}
