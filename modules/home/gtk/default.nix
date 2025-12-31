{ config, pkgs, lib, ... }:
let
  cursorName = "catppuccin-mocha-lavender-cursors";
  cursorPackage = pkgs.catppuccin-cursors.mochaLavender;
  themeName = "Catppuccin-Mocha-Standard-Lavender-Dark";
in {

  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "lavender";
    cursors.enable = true;
  };

  gtk = {
    enable = true;
    theme.name = lib.mkDefault themeName;
    cursorTheme.name = lib.mkDefault cursorName;
    # cursorTheme.package = lib.mkDefault cursorPackage;
    iconTheme.name = lib.mkDefault "Papirus-Dark";
    iconTheme.package = lib.mkDefault pkgs.papirus-icon-theme;
    
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };

  qt = {
    enable = true;
    style.name = lib.mkDefault "kvantum";
    platformTheme.name = lib.mkDefault "gtk3";
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
    };
  };

  home.sessionVariables = {
    PRISM_LAUNCHER_DARK_MODE = "1";
    GTK_THEME = themeName;
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
  };

  # xdg.desktopEntries.beeper = {
  #   name = "Beeper";
  #   exec = "beeper --enable-features=WebUIDarkMode --force-dark-mode %U";
  #   terminal = false;
  #   icon = "beeper";
  #   categories = [ "Network" "Chat" ];
  # };

  # xdg.desktopEntries."org.prismlauncher.PrismLauncher" = {
  #   name = "Prism Launcher";
  #   exec = "prismlauncher -style Fusion";
  #   icon = "org.prismlauncher.PrismLauncher";
  #   terminal = false;
  # };
}

