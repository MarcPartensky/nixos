{ pkgs, lib, ... }:

let
  aerospaceConfig = {
    config-version = 2;
    after-startup-command = [ ];
    start-at-login = true;
    enable-normalization-flatten-containers = true;
    enable-normalization-opposite-orientation-for-nested-containers = true;
    accordion-padding = 30;
    default-root-container-layout = "tiles";
    default-root-container-orientation = "auto";
    on-focused-monitor-changed = [ "move-mouse window-lazy-center" ];
    automatically-unhide-macos-hidden-apps = false;
    on-mode-changed = [ ];

    persistent-workspaces = [
      "1" "2" "3" "4" "5" "6" "7" "8" "9"
      "A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M"
      "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z"
    ];

    key-mapping.preset = "qwerty";

    gaps.inner.horizontal = 0;
    gaps.inner.vertical   = 0;
    gaps.outer.left       = 0;
    gaps.outer.bottom     = 0;
    gaps.outer.top        = 0;
    gaps.outer.right      = 0;

    mode.main.binding = {
      "cmd-m"           = "fullscreen";
      "cmd-enter"       = "exec Alacritty";
      "alt-slash"       = "layout tiles horizontal vertical";
      "alt-comma"       = "layout accordion horizontal vertical";
      "alt-h"           = "focus left";
      "alt-j"           = "focus down";
      "alt-k"           = "focus up";
      "alt-l"           = "focus right";
      "alt-shift-h"     = "move left";
      "alt-shift-j"     = "move down";
      "alt-shift-k"     = "move up";
      "alt-shift-l"     = "move right";
      "alt-minus"       = "resize smart -50";
      "alt-equal"       = "resize smart +50";
      "alt-tab"         = "workspace-back-and-forth";
      "alt-shift-tab"   = "move-workspace-to-monitor --wrap-around next";
      "alt-shift-semicolon" = "mode service";
      "alt-shift-c" = "exec-and-forget cnam";
      "cmd-shift-s" = "exec-and-forget screencapture -i ~/Desktop/screenshot-$(date +%Y%m%d-%H%M%S).png";
      "alt-1" = "workspace 1"; "alt-shift-1" = "move-node-to-workspace 1";
      "alt-2" = "workspace 2"; "alt-shift-2" = "move-node-to-workspace 2";
      "alt-3" = "workspace 3"; "alt-shift-3" = "move-node-to-workspace 3";
      "alt-4" = "workspace 4"; "alt-shift-4" = "move-node-to-workspace 4";
      "alt-5" = "workspace 5"; "alt-shift-5" = "move-node-to-workspace 5";
      "alt-6" = "workspace 6"; "alt-shift-6" = "move-node-to-workspace 6";
      "alt-7" = "workspace 7"; "alt-shift-7" = "move-node-to-workspace 7";
      "alt-8" = "workspace 8"; "alt-shift-8" = "move-node-to-workspace 8";
      "alt-9" = "workspace 9"; "alt-shift-9" = "move-node-to-workspace 9";
    };

    mode.service.binding = {
      esc       = [ "reload-config" "mode main" ];
      r         = [ "flatten-workspace-tree" "mode main" ];
      f         = [ "layout floating tiling" "mode main" ];
      backspace = [ "close-all-windows-but-current" "mode main" ];
      "alt-shift-h" = [ "join-with left"  "mode main" ];
      "alt-shift-j" = [ "join-with down"  "mode main" ];
      "alt-shift-k" = [ "join-with up"    "mode main" ];
      "alt-shift-l" = [ "join-with right" "mode main" ];
    };

    workspace-to-monitor-force-assignment = {
      "1" = "Built-in Retina Display";
      "2" = "Built-in Retina Display";
      "3" = "Built-in Retina Display";
      "4" = "Built-in Retina Display";
      "5" = "Built-in Retina Display";
      "6" = "Built-in Retina Display";
      "7" = "Built-in Retina Display";
      "8" = "Mi Monitor";
      "9" = "Mi Monitor";
    };
  };

in {
  home.packages = [ pkgs.aerospace ];

  xdg.configFile."aerospace/aerospace.toml".source =
    (pkgs.formats.toml { }).generate "aerospace.toml" aerospaceConfig;
}
