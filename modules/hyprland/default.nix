# { inputs, pkgs, lib, config, ... }:

# with lib;
# let cfg = config.modules.hyprland;

# in {
#     options.modules.hyprland= { enable = mkenableoption "hyprland"; };
#     config = mkif cfg.enable {
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

  # nix.settings = {
  #   substituters = ["https://hyprland.cachix.org"];
  #   trusted-substituters = ["https://hyprland.cachix.org"];
  #   trusted-public-keys = ["hyprland.cachix.org-1:a7pgxzmz7+chwvl3/pzj6jibmioijm7ypfp8pwtkugc="];
  # };



  # programs.dconf.enable = true;
  # programs.hyprland = {
  #   enable = true;
  #   # set the flake package
  #   package = inputs.hyprland.packages.${pkgs.stdenv.hostplatform.system}.hyprland;
  #   # make sure to also set the portal package, so that they are in sync
  #   portalpackage = inputs.hyprland.packages.${pkgs.stdenv.hostplatform.system}.xdg-desktop-portal-hyprland;
  # };


  # home-manager.users.marc = { pkgs, inputs, ... }: {
  programs.kitty.enable = true; # required for the default hyprland config
  wayland.windowManager.hyprland.enable = true; # enable hyprland
  home.sessionVariables.nixos_ozone_wl = "1";

  # home.file.".config/hypr/hyprland.conf".source = "./hyprland.conf";

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk  # for gtk apps
      xdg-desktop-portal-hyprland  # hyprland-specific portal
    ];
  };




  wayland.windowManager.hyprland.plugins = [
    # pkgs.hyprlandPlugins.hy3
    inputs.hy3.packages.${pkgs.system}.hy3
    # inputs.hyprtasking.packages.${pkgs.system}.hyprtasking
    # pkgs.hyprlandplugins.hyprspace
    # pkgs.hyprlandplugins.hycov
  ];

  wayland.windowManager.hyprland.systemd.variables = ["--all"];
  wayland.windowManager.hyprland.settings = {
    # bindm = [
    #   # "super, d, exec, kitty"
    #   "super, return , exec, kitty"
    # ];
    exec-once = [
      "${pkgs.wpaperd}/bin/wpaperd -d"
      "${pkgs.kitty}/bin/kitty"
      # "${pkgs.dbus}/bin/dbus-update-activation-environment --systemd wayland_display xdg_current_desktop"
      # "${pkgs.systemd}/bin/systemctl --user import-environment wayland_display xdg_current_desktop"
      "${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland"
      "${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal"
      "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch cliphist store" #stores only text data
      "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch cliphist store" #stores only image data
    ];

    # plugin = "/usr/lib/libhy3.so";

    monitor = [
        "edp-1,1920x1080@60,320x1440,1"
        "dp-1,2560x1440@60,0x0,1"
        "hdmi-a-1,2560x1440@60,0x0,1"
    ];

    env = [
      "dri_prime=0"
      "libva_driver_name=nvidia"
      "__glx_vendor_library_name=nvidia"
      "qt_qpa_platform=wayland"  # forces qt apps (like kodi) to use wayland
      "gtk_use_portal=1"
      "xdg_current_desktop=hyprland"
      "xdg_session_desktop=hyprland"
      "qt_qpa_platform=wayland;xcb"
      "sdl_videodriver=wayland"
      "clutter_backend=wayland"
      "nixos_ozone_wl=1"       
      "gdk_backend=wayland"
      "qt_wayland_force_dpi=physical"
      "gdk_dpi_scale=1"
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
      # hyprspace = {
      #     overview = {
      #         close = 0;
      #         disablegestures = 1;
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
      # kb_options = "caps:escape";
      # kb_rules=
    
      follow_mouse = 1;
      natural_scroll = true;
      touchpad = {
          natural_scroll = true;
          disable_while_typing = false;
          middle_button_emulation = true;
          tap-to-click = true;
      };

      kb_options = "caps:escape,prior:shift_l";
      # mapping personnalisé avec xkb
      # kb_custom_rules = ''
      #   partial alphanumeric_keys
      #   xkb_symbols "prior" {
      #     key <prior> { [ shift_l ] };
      #   };
      # '';
    };

    general  = {
        # sensitivity=1 # for mouse cursor
        # main_mod=super
    
        gaps_in = 5;
        gaps_out = 10;
        # border_size=2
        border_size = 0;
        "col.active_border" = "0x66ee1111";
        "col.inactive_border" = "0x66333333";
    
        # apply_sens_to_raw=0 # whether to apply the sensitivity to raw input (e.g. used by games where you aim using your mouse)
    
        # damage_tracking=full # leave it on full unless you hate your gpu and want to make it suffer
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

      "workspace 1,title:^(alacritty)$"
      # windowrule=float,^(alacritty)$
      # windowrule=size 50% 95%,^(alacritty)$

      "center,title:^(alacritty)$"
      "workspace 2,title:^(firefox)$"
      "workspace 3,title:^(spotify)$"
      "workspace 3,title:^(spotube)$"
      "workspace 4,title:^(webcord)$"
      "workspace 4,title:^(discord)$"
      "workspace 4,title:^(whatsapp)$"
      "workspace 4,title:^(element)$"
      "workspace 4,title:^(instagram)$"
      # windowrule=fakefullscreen,title:^(signal)$

      "workspace 4,title:^(signal)$"
      "workspace 4,title:^(caprine)$"
      "workspace 5,title:^(mailspring)$"
      # windowrule=fakefullscreen,title:^(mailspring)$
      "workspace 5,title:^(geary)$"
      "workspace 5,title:^(proton-mail-viewer)$"
      # windowrule=fakefullscreen,title:^(proton-mail-viewer)$
      "workspace 9,title:^(nautilus)$"
      "workspace 10,title:^(focalboard)$"

      "workspace 1,title:^(youtube)$"
      "workspace 2,title:^(firefox)$"
    ];

    workspace = [
      # workspace=name:myworkspace,gapsin:0,gapsout:
      "1, name:coding, rounding:true, decorate:false, gapsin:5, gapsout:10, border:true, decorate:true, monitor:edp-1"
      "2, name:browser, monitor:edp-1"
      "3, name:music, monitor:edp-1"
      "4, name:chat, monitor:edp-1"
      "5, name:mail, monitor:edp-1"
      "10, name:board, monitor:edp-1"
    ];


  };

  home.pointerCursor = {
    gtk.enable = true;
    # x11.enable = true;
    package = pkgs.bibata-cursors;
    name = "bibata-modern-classic";
    size = 16;
  };

#   gtk = {
#     enable = true;
# 
#     theme = {
#       package = pkgs.flat-remix-gtk;
#       name = "flat-remix-gtk-grey-darkest";
#     };
# 
#     icontheme = {
#       package = pkgs.adwaita-icon-theme;
#       name = "adwaita";
#     };
# 
#     font = {
#       name = "sans";
#       size = 11;
#     };
#   };
  # gtk = {
  #   enable = true;
  #   theme = {
  #     # name = "adwaita";
  #     # package = pkgs.adwaita-icon-theme;
  #     package = pkgs.flat-remix-gtk;
  #     name = "flat-remix-gtk-grey-darkest";
  #   };
  #   iconTheme = {
  #     name = "adwaita";
  #     package = pkgs.adwaita-icon-theme;
  #   };
  #   gtk3.extraConfig = {
  #     gtk-application-prefer-dark-theme = 0;
  #     gtk-xft-antialias = 1;
  #     gtk-xft-hinting = 1;
  #     gtk-xft-hintstyle = "hintslight";
  #     gtk-xft-rgba = "rgb";
  #   };
  # };
  gtk = {
    enable = true;
    theme = {
      name = "Colloid-Dark";
      package = pkgs.colloid-gtk-theme;
    };
    cursorTheme = {
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
    };
    iconTheme = {
      package = pkgs.papirus-icon-theme;
      name = "Papirus-Dark";
    };
  };
}
