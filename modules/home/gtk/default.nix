{
  config,
  pkgs,
  lib,
  ...
}: let
  cursorName = "catppuccin-mocha-lavender-cursors";
  cursorPackage = pkgs.catppuccin-cursors.mochaLavender;
  themeName = "catppuccin-mocha-lavender-standard+rimless,black";

  # On définit le paquet explicitement pour être sûr
  catppuccinThemePkg = pkgs.catppuccin-gtk.override {
    accents = ["lavender"];
    size = "standard";
    tweaks = ["rimless" "black"]; # Ajustez selon vos gouts
    variant = "mocha";
  };

  # On récupère le dépôt catppuccin/libreoffice
  catppuccinLibreOffice = pkgs.fetchFromGitHub {
    owner = "catppuccin";
    repo = "libreoffice";
    rev = "main"; # Vous pouvez épingler un commit spécifique pour la stabilité
    hash = "sha256-NAQJPIbJVUZFkFfdyywv1A38N06gwdLd5Uge6eqPPJM=";
  };

  flavor = "mocha";
  accent = "lavender";

  patchScript = pkgs.writeShellScriptBin "catppuccin-lo-patch" ''
    # On crée un dossier de travail temporaire
    WORK_DIR=$(mktemp -d)

    echo "Copie des fichiers du thème..."
    cp -r ${catppuccinLibreOffice}/* "$WORK_DIR"
    chmod -R +w "$WORK_DIR"

    cd "$WORK_DIR"

    echo "Application du thème Catppuccin (${flavor} ${accent}) pour LibreOffice..."
    # On exécute le script officiel
    bash scripts/install_theme.sh "${flavor}" "${accent}"

    # Nettoyage
    rm -rf "$WORK_DIR"
    echo "Terminé ! Relancez LibreOffice."
  '';
in {
  xdg.configFile."libreoffice/4/user/config/catppuccin-${flavor}-${accent}.soc".source = "${catppuccinLibreOffice}/themes/${flavor}/${accent}/catppuccin-${flavor}-${accent}.soc";

  home.packages = with pkgs; [
    gnome-themes-extra # Base absolue pour GTK

    arc-theme # Thème Arc (très standard)
    dracula-theme # Thème Dracula (très contrasté)

    patchScript
  ];

  catppuccin = {
    enable = true;
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

  xdg.desktopEntries.beeper = {
    name = "Beeper";
    exec = "beeper --enable-features=WebUIDarkMode --force-dark-mode %U";
    terminal = false;
    icon = "beeper";
    categories = ["Network" "Chat"];
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
