{ pkgs, home-manager, inputs, ... }:
{

  imports =
    [
      ../../modules/git
      # ../../modules/hyprland
    ];



  # home.file.".config/hypr/hyprland.conf".source = ../../modules/hyprland/hyprland.conf;

  home-manager.backupFileExtension = "backup";


  home-manager.users.marc = { pkgs, inputs, ... }: {
    home.packages = with pkgs; [
      # cli
      bat
      tmate
      typer
      yt-dlp
      uv

      # gui
      wasistlos
      nextcloud-client
      jellyfin-web
      invidious
      tor-browser
      signal-desktop
      kodi
      mpv
      wpaperd
      wofi
      rofi
      wdisplays
      wl-clipboard-rs
      wayvnc
    ];

    # programs.zsh.enable = true;
    # programs.librewolf = {
    #   enable = true;
    #   # Enable WebGL, cookies and history
    #   settings = {
    #     "webgl.disabled" = false;
    #     "privacy.resistFingerprinting" = false;
    #     "privacy.clearOnShutdown.history" = false;
    #     "privacy.clearOnShutdown.cookies" = false;
    #     "network.cookie.lifetimePolicy" = 0;
    #   };
    # };

    programs.kitty.enable = true; # required for the default Hyprland config
    wayland.windowManager.hyprland.enable = true; # enable Hyprland

# bind=,XF86AudioRaiseVolume,exec,pamixer -i 5
# bind=,XF86AudioLowerVolume,exec,pamixer -d 5
# bind=,XF86AudioMute,exec,pamixer -t

    wayland.windowManager.hyprland.settings = {
      "$mod" = "SUPER";
      bind =
        [
          "$mod, d, exec, wofi --show drun"
          ", Print, exec, grimblast copy area"
          "$mod, v, togglefloating"
          "$mod, m, fullscreen"
          "$mod, return, exec, alacritty"
        ]
        ++ (
          # workspaces
          # binds $mod + [shift +] {1..9} to [move to] workspace {1..9}
          builtins.concatLists (builtins.genList (i:
              let ws = i + 1;
              in [
                "$mod, code:1${toString i}, workspace, ${toString ws}"
                "$alt, code:1${toString i}, movetoworkspace, ${toString ws}"
              ]
            )
            9)
        );
    };
   # wayland.windowManager.hyprland.plugins = [
   #   inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hy3
   #   "/usr/lib/hy3.so"
   # ];

    programs.firefox = {
      enable = true;
      package = pkgs.librewolf;
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
  
    # The state version is required and should stay at the version you
    # originally installed.
    home.stateVersion = "25.05";
  };

}
