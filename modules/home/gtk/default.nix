{
  config,
  pkgs,
  lib,
  ...
}: let
  cursorName = "catppuccin-mocha-lavender-cursors";
  cursorPackage = pkgs.catppuccin-cursors.mochaLavender;
  themeName = "catppuccin-mocha-lavender-standard+rimless,black";

  # Define the package explicitly to be sure
  catppuccinThemePkg = pkgs.catppuccin-gtk.override {
    accents = ["lavender"];
    size = "standard";
    tweaks = ["rimless" "black"]; # Adjust to your taste
    variant = "mocha";
  };

  # Fetch the catppuccin/libreoffice repo
  catppuccinLibreOffice = pkgs.fetchFromGitHub {
    owner = "catppuccin";
    repo = "libreoffice";
    rev = "main"; # You can pin a specific commit for stability
    hash = "sha256-NAQJPIbJVUZFkFfdyywv1A38N06gwdLd5Uge6eqPPJM=";
  };

  flavor = "mocha";
  accent = "lavender";

  patchScript = pkgs.writeShellScriptBin "catppuccin-lo-patch" ''
    # Create a temporary work directory
    WORK_DIR=$(mktemp -d)

    echo "Copying theme files..."
    cp -r ${catppuccinLibreOffice}/* "$WORK_DIR"
    chmod -R +w "$WORK_DIR"

    cd "$WORK_DIR"

    echo "Applying the Catppuccin theme (${flavor} ${accent}) for LibreOffice..."
    # Run the official script
    bash scripts/install_theme.sh "${flavor}" "${accent}"

    # Cleanup
    rm -rf "$WORK_DIR"
    echo "Done! Restart LibreOffice."
  '';
in {
  xdg.configFile."libreoffice/4/user/config/catppuccin-${flavor}-${accent}.soc".source = "${catppuccinLibreOffice}/themes/${flavor}/${accent}/catppuccin-${flavor}-${accent}.soc";

  home.packages = with pkgs; [
    gnome-themes-extra # Absolute base for GTK

    arc-theme # Arc theme (very standard)
    dracula-theme # Dracula theme (very high contrast)

    patchScript
  ];

  catppuccin = {
    enable = true;
    # explicit: catppuccin/nix will switch auto-enrollment to autoEnable
    autoEnable = true;
    flavor = "mocha";
    accent = "lavender";
    cursors.enable = true;
    zathura.enable = true;
    spotify-player.enable = true;
  };

  gtk = {
    enable = true;
    theme.name = lib.mkDefault themeName;
    theme.package = catppuccinThemePkg;
    cursorTheme.name = lib.mkDefault cursorName;
    iconTheme.name = lib.mkDefault "Papirus-Dark";
    iconTheme.package = lib.mkDefault pkgs.papirus-icon-theme;
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
    # legacy behavior (stateVersion < 26.05): GTK4 follows the GTK theme
    gtk4.theme = config.gtk.theme;
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
    "org/gnome/nautilus/preferences" = {
      show-image-thumbnails = "always";
      thumbnail-limit = 100;
    };
  };

  home.sessionVariables = {
    PRISM_LAUNCHER_DARK_MODE = "1";
    GTK_THEME = themeName;
    ADW_DISABLE_PORTAL = "1";
    SAL_USE_VCLPLUGIN = "gtk4";
  };

  xdg.desktopEntries.electron-mail = {
    name = "Electron Mail";
    exec = "electron-mail --ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --force-dark-mode %U";
    terminal = false;
    icon = "electron-mail";
    categories = ["Network" "Email"];
  };

  xdg.desktopEntries.libreoffice-calc = {
    name = "LibreOffice Calc";
    icon = "libreoffice-calc";
    exec = "env GTK_THEME=Dracula libreoffice --calc";
    terminal = false;
    categories = ["Office" "Spreadsheet"];
    mimeType = ["application/vnd.oasis.opendocument.spreadsheet" "application/vnd.ms-excel"];
  };
}
