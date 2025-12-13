{ pkgs, ... }:

let
  screenshotsDir = "media/screenshots/";
in
{
  # Dossier de sortie des screenshots (créé automatiquement)
  # home.file."${screenshotsDir}/.ignore".source = "../../Justfile";

  programs.satty = {
    enable = true;

    settings = {
      general = {
        fullscreen = true;
        corner-roundness = 12;
        initial-tool = "brush";

        # Format et chemin de sortie (relatif à $HOME)
        save-format = "png";
        output-filename =
          "${screenshotsDir}/%Y-%m-%d_%H:%M:%S.png";

        # Notifications système
        notifications = true;
      };

      # Actions après sauvegarde
      post-actions = [
        {
          command = "wl-copy < {file}";
          description = "Copy screenshot to clipboard";
        }
      ];

      color-palette = {
        palette = [
          "#00ffff"
          "#a52a2a"
          "#dc143c"
          "#ff1493"
          "#ffd700"
          "#008000"
        ];
      };
    };
  };
}

