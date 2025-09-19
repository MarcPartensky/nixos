{ pkgs, ... }:

{
  xdg.configFile."satty/config.yml".text = ''
    output_directory: ~/Pictures/screenshots
    save_format: "png"
    notifications: true

    # exemple d’intégration avec wl-copy (Wayland)
    post_actions:
      - command: "wl-copy < {file}"
        description: "Copy to clipboard"
  '';
}
