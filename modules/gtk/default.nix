{ config, pkgs, lib, ... }:
let
  # name = "Colloid-Dark";
  #name = "Colloid-Dark";
  name = "Catppucin-Mocha";
 #  package = pkgs.colloid-gtk-theme;
  package = pkgs.catppuccin;
  #   name = "Adwaita-dark";  # ou autre thème
  #   package = pkgs.gnome-themes-extra;
  # package = pkgs.papirus-icon-theme;
  # name = "Papirus-Dark";
in {

  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "pink";
  };

  gtk = {
    enable = true;
    theme.name = lib.mkDefault name;
    cursorTheme.name = lib.mkDefault name;
    iconTheme.name = lib.mkDefault name;
    colorScheme = lib.mkDefault "dark";
    # font = {
    #   name = "sans";
    #   size = 11;
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
      # name = name;       # style forcé (dark si ton kvantum est dark)
      name = "kvantum";
      package = package;
    };
  
    # Indique à toutes les apps Qt que tu es en dark mode
    platformTheme.name = "gtk3";   # Qt suit le thème sombre GTK
  };

}
