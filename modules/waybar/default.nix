{ inputs, pkgs, ... }: {

  home-manager.users.marc = { pkgs, inputs, ... }: {


    home.packages = with pkgs; [
      wttrbar
    ];

    programs.waybar = {
      enable = true;
      systemd = {
        enable = true;
        target = "graphical-session.target";
      };
      settings = {
        mainBar = {
          name = "bar0";
          layer = "top";
          position = "top";
          height = 10;
          margin = "5";
          spacing = 10;
          mode = "top";
          output = "eDP-1";
          reload_style_on_change = true;

          modules-left = [ "hyprland/workspaces" ];
          modules-center = [ "hyprland/window" ];
          modules-right = [
            # "tray"
            "custom/weather"
            "idle_inhibitor"
            "backlight"
            "wireplumber"
            "battery"
            "disk"
            "memory"
            "cpu"
            "temperature"
            "clock"
          ];

          idle_inhibitor = {
            format = "{icon}";
            format-icons = {
              activated = "󰛊 ";
              deactivated = "󰾫 ";
            };
          };

          backlight = {
            interval = 2;
            format = "󰖨 {percent}%";
            on-scroll-up = "brightnessctl set +4";
            on-scroll-down = "brightnessctl set 4-";
          };

          wireplumber = {
            format = "{icon} {volume}%";
            format-muted = "󰝟 ";
            on-click = "amixer sset Master toggle";
            format-icons = [ "" "" "" "" "" ];
          };

          battery = {
            interval = 10;
            format = "{icon}{capacity}%";
            format-icons = [ "󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
            tooltip = true;
            tooltip-format = "{timeTo}";
          };

          disk = {
            interval = 30;  # Fixed typo (was intervel)
            format = "󰋊 {percentage_used}%";
            tooltip-format = "{used} used out of {total} on \"{path}\" ({percentage_used}%)";
          };

          memory = {
            interval = 10;
            format = " {used}";
            tooltip-format = "{used}GiB used of {total}GiB ({percentage}%)";
          };

          cpu = {
            interval = 10;
            format = " {usage}%";
          };

          temperature = {
            interval = 10;
          };

          clock = {
            interval = 1;
            format = "{:%H:%M:%S}";
          };

          "custom/weather" = {
            format = "{}°";
            tooltip = true;
            interval = 3600;
            exec = "wttrbar";
            return-type = "json";
          };

          "hyprland/workspaces" = {
            show-special = true;
            persistent-workspaces = {
              "*" = [1 2 3 4 5 6 7 8 9 10];
            };
            format = "{icon}";
            format-icons = {
              active = "";
              empty = "";
              default = "";
              urgent = "";
              special = "󰠱";
            };
          };

          "hyprland/window" = {
            icon = true;
            icon-size = 22;
            rewrite = {
              "(.*) — Mozilla Firefox" = "$1 - 🦊";
              "(.*) - Neovim" = "$1 - 󰨞 ";
              "(.*) - Discord" = "$1 - 󰙯 ";
              "^$" = "👾";
            };
          };
        };
      };

      # Keep your existing style
       style = ''
       window#waybar {
            font-family: "MesloLGS Nerd Font";  /* Changed font */
            background-color: rgba(0,0,0,0);
            font-size: 1.2rem;  /* Increased from 0.8rem (0.8 * 1.5 = 1.2) */
            border-radius: 0.5rem;
        }

        .modules-left, .modules-center {
            opacity: 1;
            background: linear-gradient(45deg, rgb(214, 39, 200), rgb(5, 83, 252));
            border-radius: 0.5rem;
            padding: 2px;
        }

        .modules-right {
            opacity: 1;
            background-color: rgba(0,0,0,0.5);
            border-radius: 0.5rem;
            padding: 2px 2px 2px 10px
        }

        #workspaces {
            background-color: rgba(0,0,0,0.5);
            border-radius: 0.5rem;
            padding: 0 2px;
        }

        #workspaces button {
            font-size: 0.9rem;  /* Increased from 0.6rem (0.6 * 1.5 = 0.9) */
            padding: 0 0.3rem 0 0;
        }

        #window {
            background-color: rgba(0,0,0,0.5);
            border-radius: 0.5rem;
            padding: 2px 5px;
        }

        #clock {
            font-weight: bolder;
            border-radius: 0.5rem;
            padding: 0 3px 0 0;
        }

        #battery {
            color: lightgreen;
        }

        #memory {
            color: lightpink;
        }

        #disk {
            color: lightskyblue;
        }

        #cpu {
            color: lightgoldenrodyellow;
        }

        #temperature {
            color: lightslategray;
        }
      '';
    };
  };
}
