{ pkgs, ... }:

let
  screenshotsDir = "media/screenshots/";
in
{
  # Screenshots output directory (created automatically)
  # home.file."${screenshotsDir}/.ignore".source = "../../Justfile";

  programs.satty = {
    enable = true;

    settings = {
      general = {
        fullscreen = true;
        corner-roundness = 12;
        initial-tool = "brush";

        # Output format and path (relative to $HOME)
        save-format = "png";
        output-filename =
          "${screenshotsDir}/%Y-%m-%d_%H:%M:%S.png";

        # System notifications
        notifications = true;
      };

      # Actions after saving
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

