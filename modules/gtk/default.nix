{ config, pkgs, ... }:
let
  name = "Colloid-Dark";
  package = pkgs.colloid-gtk-theme;
  #   name = "Adwaita-dark";  # ou autre thème
  #   package = pkgs.gnome-themes-extra;
  # package = pkgs.papirus-icon-theme;
  # name = "Papirus-Dark";
in {
  # Thème GTK pour GTK3 et GTK4
  gtk = {
    enable = true;
    theme = {
      name = name;
      package = package;
    };
    cursorTheme = {
      name = name;
      package = package;
    };
    iconTheme = {
      name = name;
      package = package;
    };
    # font = {
    #   name = "sans";
    #   size = 11;
    # };
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = 0;
      gtk-xft-antialias = 1;
      gtk-xft-hinting = 1;
      gtk-xft-hintstyle = "hintslight";
      gtk-xft-rgba = "rgb";
    };
    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = 0;
      gtk-xft-antialias = 1;
      gtk-xft-hinting = 1;
      gtk-xft-hintstyle = "hintslight";
      gtk-xft-rgba = "rgb";
    };
  };

  # Forcer l'interface en mode dark (utile pour apps qui respectent gtk-theme-variant)
  # dconf.settings."org/gnome/desktop/interface" = {
  #   color-scheme = "prefer-dark";
  #   gtk-theme = "Adwaita-dark";
  # };

  home.pointerCursor = {
    gtk.enable = true;
    # x11.enable = true;
    name = name;
    package = package;
    size = 16;
  };

  qt = {
    enable = true;
  
    style = {
      name = name;       # style forcé (dark si ton kvantum est dark)
      package = package;
    };
  
    # Indique à toutes les apps Qt que tu es en dark mode
    platformTheme.name = "gtk3";   # Qt suit le thème sombre GTK
  };

}
