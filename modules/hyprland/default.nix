# { inputs, pkgs, lib, config, ... }:

# with lib;
# let cfg = config.modules.hyprland;

# in {
#     options.modules.hyprland= { enable = mkEnableOption "hyprland"; };
#     config = mkIf cfg.enable {
# 	home.packages = with pkgs; [
# 	    wofi swaybg wlsunset wl-clipboard hyprland
# 	];

#         home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;
#     };
# }

{inputs, pkgs, ...}: {
  # home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;

  imports = [
    ./bindings.nix
  ];

  nix.settings = {
    substituters = ["https://hyprland.cachix.org"];
    trusted-substituters = ["https://hyprland.cachix.org"];
    trusted-public-keys = ["hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="];
  };



  programs.dconf.enable = true;
  programs.hyprland = {
    enable = true;
    # set the flake package
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };


  home-manager.users.marc = { pkgs, inputs, ... }: {
    programs.kitty.enable = true; # required for the default Hyprland config
    wayland.windowManager.hyprland.enable = true; # enable Hyprland
    home.sessionVariables.NIXOS_OZONE_WL = "1";

    wayland.windowManager.hyprland.plugins = [
      pkgs.hyprlandPlugins.hy3
      # pkgs.hyprlandPlugins.hyprspace
      # pkgs.hyprlandPlugins.hycov
    ];

# bind=,XF86AudioRaiseVolume,exec,pamixer -i 5
# bind=,XF86AudioLowerVolume,exec,pamixer -d 5
# bind=,XF86AudioMute,exec,pamixer -t

    wayland.windowManager.hyprland.settings = {
      exec-once = "wpaperd -d";

      # plugin = "/usr/lib/libhy3.so";

      monitor = [
          "eDP-1,1920x1080@60,320x1440,1"
          "DP-1,2560x1440@60,0x0,1"
          "HDMI-A-1,2560x1440@60,0x0,1"
      ];

      env = [
        "DRI_PRIME=0"
        "LIBVA_DRIVER_NAME,nvidia"
        "__GLX_VENDOR_LIBRARY_NAME,nvidia"
      ];


      plugins = {


        hy3 = {
            tabs = {
                height = 2;
	              padding = 6;
	              render_text = false;
            };

            autotile = {
                enable = true;
                trigger_width = 1500;
                trigger_height = 500;
            };
        };
        # Hyprspace = {
        #     overview = {
        #         close = 0;
        #         disableGestures = 1;
        #     };
        #     gestures = {
        #         workspace_swipe_fingers = 5;
        #     };
        # };
      };

      debug  = {
          disable_logs = false;
      };

      input = {
          kb_layout = "fr";
          kb_variant = "us";
          # kb_model=
          kb_options = "caps:escape";
          # kb_rules=
      
          follow_mouse = 1;
          natural_scroll = true;
          touchpad = {
              natural_scroll = true;
              disable_while_typing = false;
              middle_button_emulation = true;
              tap-to-click = true;
          };
      };

      general  = {
          # sensitivity=1 # for mouse cursor
          # main_mod=SUPER
      
          gaps_in = 5;
          gaps_out = 10;
          # border_size=2
          border_size = 0;
          "col.active_border" = "0x66ee1111";
          "col.inactive_border" = "0x66333333";
      
          # apply_sens_to_raw=0 # whether to apply the sensitivity to raw input (e.g. used by games where you aim using your mouse)
      
          # damage_tracking=full # leave it on full unless you hate your GPU and want to make it suffer
          # layout=dwindle
          layout = "hy3";
          resize_on_border = true;
      };

      decoration = {
          rounding = 5;
      };

      animations  = {
          enabled = 1;
          # bezier=overshot,0.05,0.9,0.1,1.1
          bezier = "overshot,0.13,0.99,0.29,1.1";
          animation = [
            "windows,1,4,overshot,slide"
            "border,1,10,default"
            "fade,1,10,default"
            "workspaces,1,10,overshot,slidevert"
          ];
      
          # animation=workspaces,1,6,overshot,slide
          # animation=workspaces,11,20,overshot,slide
      };

      dwindle = {
          pseudotile = 0; # enable pseudotiling on dwindle
      };
      
      
      gestures = {
          workspace_swipe = true;
          workspace_swipe_fingers = 3;
      };
      
      misc = {
          disable_hyprland_logo = true;
      };


      windowrule = [
        "float,title:^(blueberry.py)$"
        "size 40% 85%,title:^(blueberry.py)$"
        "center,title:^(blueberry.py)$"

        "float,title:^(org.twosheds.iwgtk)$"
        "size 40% 85%,title:^(org.twosheds.iwgtk)$"
        "center,title:^(org.twosheds.iwgtk)$"

        "size 50% 50%,title:^(wdisplays)$"
        "float,title:^(wdisplays)$"
        "center,title:^(wdisplays)$"

        "workspace 1,title:^(Alacritty)$"
        # windowrule=float,^(Alacritty)$
        # windowrule=size 50% 95%,^(Alacritty)$

        "center,title:^(Alacritty)$"
        "workspace 2,title:^(firefox)$"
        "workspace 3,title:^(Spotify)$"
        "workspace 3,title:^(Spotube)$"
        "workspace 4,title:^(WebCord)$"
        "workspace 4,title:^(Discord)$"
        "workspace 4,title:^(Whatsapp)$"
        "workspace 4,title:^(Element)$"
        "workspace 4,title:^(Instagram)$"
        # windowrule=fakefullscreen,title:^(Signal)$

        "workspace 4,title:^(Signal)$"
        "workspace 4,title:^(Caprine)$"
        "workspace 5,title:^(Mailspring)$"
        # windowrule=fakefullscreen,title:^(Mailspring)$
        "workspace 5,title:^(Geary)$"
        "workspace 5,title:^(proton-mail-viewer)$"
        # windowrule=fakefullscreen,title:^(proton-mail-viewer)$
        "workspace 9,title:^(nautilus)$"
        "workspace 10,title:^(Focalboard)$"

        "workspace 1,title:^(youtube)$"
        "workspace 2,title:^(firefox)$"
      ];

      workspace = [
        # workspace=name:myworkspace,gapsin:0,gapsout:
        "1, name:coding, rounding:true, decorate:false, gapsin:5, gapsout:10, border:true, decorate:true, monitor:eDP-1"
        "2, name:browser, monitor:eDP-1"
        "3, name:music, monitor:eDP-1"
        "4, name:chat, monitor:eDP-1"
        "5, name:mail, monitor:eDP-1"
        "10, name:board, monitor:eDP-1"
      ];


      "$mod" = "SUPER";
    };

    home.pointerCursor = {
      gtk.enable = true;
      # x11.enable = true;
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };
  
    gtk = {
      enable = true;
  
      theme = {
        package = pkgs.flat-remix-gtk;
        name = "Flat-Remix-GTK-Grey-Darkest";
      };
  
      iconTheme = {
        package = pkgs.adwaita-icon-theme;
        name = "Adwaita";
      };
  
      font = {
        name = "Sans";
        size = 11;
      };
    };
  };
}
