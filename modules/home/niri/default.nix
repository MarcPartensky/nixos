{
  pkgs,
  lib,
  ...
}: let
  # --- SCREENSHOTS CONFIGURATION ---
  screenshotDir = "~/media/screenshots";
  # Format: Year-Month-Day_Hour-Min-Sec (e.g. 2024-05-20_14-30-05)
  screenshotFormat = "$(date +%Y-%m-%d_%H-%M-%S).png";
in {
  # Make sure niri and alacritty are installed
  home.packages = with pkgs; [
    pkgs.alacritty
    pkgs.niri
    pkgs.xwayland-satellite

    # Your "separate" script
    (writeShellScriptBin "niri-reset" ''
      ${bluez}/bin/bluetoothctl devices | cut -f2 -d' ' | while read -r uuid; do
        ${bluez}/bin/bluetoothctl connect "$uuid"
      done
      systemctl restart NetworkManager
    '')
  ];

  systemd.user.sessionVariables = {
    DISPLAY = ":0";
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    GDK_BACKEND = "wayland";
    QT_QPA_PLATFORM = "wayland";
    XDG_CURRENT_DESKTOP = "niri";
    XDG_SESSION_TYPE = "wayland";
  };

  xdg.portal = {
    enable = true;
    config.common.default = "gtk";
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk # fallback UI
      xdg-desktop-portal-gnome
    ];
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
    };
  };

  # Make sure the user dbus services are there
  #services.dbus.enable = true;
  home.sessionVariables = {
    # Force Electron/Chromium to use Wayland
    NIXOS_OZONE_WL = "1";
    # Tell Qt apps to use wayland
    QT_QPA_PLATFORM = "wayland";
    # Tell SDL apps to use wayland
    SDL_VIDEODRIVER = "wayland";
    # For Mozilla (if needed)
    MOZ_ENABLE_WAYLAND = "1";
    # Standard XDG variables
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "niri";
    GTK_IS_WIDGET = 0;
  };

  programs.niri = {
    package = pkgs.niri;
    # package = inputs.niri.packages.${pkgs.system}.niri-stable;
    settings = {
      outputs = {
        "eDP-1" = {
          mode = {
            width = 1920;
            height = 1080;
            refresh = 60.027;
          };
          position = {
            x = 0;
            y = 0;
          };
        };

        "DP-1" = {
          mode = {
            width = 2560;
            height = 1440;
            refresh = 59.951;
          };
          position = {
            x = -320;
            y = -1440;
          };
        };
        "Technical Concepts Ltd 32S331 Unknown" = {
          scale = 1.5;
        };
      };

      prefer-no-csd = true; # no bar

      input.keyboard.xkb = {
        layout = "fr";
        variant = "us"; # "us" to have the qwerty layout but typed FR
      };

      input = {
        mod-key = "Super";
        # mod-key-nested = "Alt";
        mod-key-nested = "Super";
      };

      binds =
        {
          # --- Vim navigation ---
          # Columns (Left / Right)
          "Mod+H".action.focus-column-left = [];
          "Mod+L".action.focus-column-right = [];

          # Workspaces (Next / Previous)
          "Mod+J".action.focus-workspace-down = [];
          "Mod+K".action.focus-workspace-up = [];

          # --- Existing navigation ---
          "Mod+Q".action.close-window = [];
          "Mod+Left".action.focus-column-left = [];
          "Mod+Right".action.focus-column-right = [];
          "Mod+Up".action.focus-window-or-monitor-up = [];
          "Mod+Down".action.focus-window-or-monitor-down = [];
          "Mod+Shift+E".action.quit = [];
          "Mod+Space".action.toggle-overview = [];

          # --- Applications ---
          "Mod+D".action.spawn = ["wofi" "--show" "drun"];
          "Mod+Return".action.spawn = "alacritty";
          "Mod+F".action.spawn = "librewolf";
          "Mod+B".action.spawn = ["gtk-launch" "blueberry"];
          "Alt+L".action.spawn = "nautilus";

          # --- Window management ---
          "Mod+R".action.spawn = ["niri-reset"];
          "Mod+M".action.maximize-column = [];
          "Mod+V".action.toggle-window-floating = [];
          "Mod+C".action.close-window = [];
          "Mod+T".action.set-column-width = "50%";
          "Mod+Y".action.set-column-width = "33%";
          "Super+Shift+C".action.close-window = [];
          "Super+Shift+Q".action.quit.skip-confirmation = true;

          # PRINT: Direct -> Folder + Clipboard (Automatic)
          "Print".action.spawn = [
            "sh"
            "-c"
            "grim -g \"$(slurp)\" - | tee ${screenshotDir}/${screenshotFormat} | wl-copy"
          ];

          # MOD + PRINT: Edit -> Satty (Interactive)
          # Satty then lets you choose to save or copy via its interface
          "Mod+Print".action.spawn = [
            "sh"
            "-c"
            "grim -g \"$(slurp)\" - | satty -f - --output-filename ${screenshotDir}/${screenshotFormat}"
          ];

          # --- Multimedia ---
          "Prior".action.spawn = "wl-copy";
          "Next".action.spawn = "wl-paste";
          "Alt+D".action.spawn = ["playerctl" "-p" "spotify" "next"];
          "Alt+S".action.spawn = ["playerctl" "-p" "spotify" "previous"];
          "Alt+K".action.spawn = ["playerctl" "-p" "spotify" "play-pause"];
          "Alt+W".action.spawn = ["auto-wallpaper"];

          # --- Hardware ---
          "XF86AudioRaiseVolume".action.spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "2%+"];
          "XF86AudioLowerVolume".action.spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "2%-"];
          "XF86AudioMute".action.spawn = ["wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"];
          "XF86MonBrightnessUp".action.spawn = ["brightnessctl" "s" "+1%"];
          "XF86MonBrightnessDown".action.spawn = ["brightnessctl" "s" "1%-"];
        }
        // lib.attrsets.mergeAttrsList (map (
          i: let
            ws = toString i;
          in {
            "Alt+${ws}".action.move-window-to-workspace = i;
            "Mod+${ws}".action.focus-workspace = i;
          }
        ) [1 2 3 4 5 6 7 8 9]);

      # Automatic startup
      spawn-at-startup = [
        {argv = ["${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal"];}
        {argv = ["dbus-update-activation-environment" "--systemd" "all"];}
        {argv = ["systemctl" "--user" "import-environment" "PATH" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP"];}
        {argv = ["xwayland-satellite" ":"];}

        {argv = ["alacritty"];}
        {argv = ["zen"];}
        {argv = ["spotify"];}
      ];

      overview.zoom = 0.2;
      input.mouse.natural-scroll = true;
      input.focus-follows-mouse.enable = true;

      outputs = {
        "eDP-1" = {
          enable = true;
          scale = 1;
        };
      };

      # A few visual tweaks so you do not get lost
      layout = {
        default-column-width = {
          # proportion = 0.33;
          proportion = 0.5;
        };
        border.enable = false;
        focus-ring.enable = false;
        shadow.enable = true;
      };

      window-rules = [
        {
          matches = [{app-id = "Alacritty";}];
          open-maximized = true;
          open-on-workspace = "1";
        }
        {
          matches = [{app-id = "^zen";}];
          open-on-workspace = "2";
        }
        {
          matches = [{app-id = "Spotify";}];
          open-on-workspace = "3";
        }
        {
          matches = [{is-active = false;}];
          shadow = {
            enable = true;
            softness = 10;
            spread = 2;
            color = "#00000044";
          };
        }
      ];
    };
  };
}
