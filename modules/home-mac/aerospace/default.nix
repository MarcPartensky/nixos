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
      "cmd-slash"       = "layout tiles horizontal vertical";
      "cmd-comma"       = "layout accordion horizontal vertical";
      "cmd-h"           = "focus left";
      "cmd-j"           = "focus down";
      "cmd-k"           = "focus up";
      "cmd-l"           = "focus right";
      "cmd-shift-h"     = "move left";
      "cmd-shift-j"     = "move down";
      "cmd-shift-k"     = "move up";
      "cmd-shift-l"     = "move right";
      "cmd-minus"       = "resize smart -50";
      "cmd-equal"       = "resize smart +50";
      "cmd-tab"         = "workspace-back-and-forth";
      "cmd-shift-tab"   = "move-workspace-to-monitor --wrap-around next";
      "cmd-shift-semicolon" = "mode service";
      "cmd-shift-c" = "exec-and-forget cnam";
      "cmd-shift-s" = "exec-and-forget screencapture -i ~/Desktop/screenshot-$(date +%Y%m%d-%H%M%S).png";
      "cmd-1" = "workspace 1"; "alt-shift-1" = "move-node-to-workspace 1";
      "cmd-2" = "workspace 2"; "alt-shift-2" = "move-node-to-workspace 2";
      "cmd-3" = "workspace 3"; "alt-shift-3" = "move-node-to-workspace 3";
      "cmd-4" = "workspace 4"; "alt-shift-4" = "move-node-to-workspace 4";
      "cmd-5" = "workspace 5"; "alt-shift-5" = "move-node-to-workspace 5";
      "cmd-6" = "workspace 6"; "alt-shift-6" = "move-node-to-workspace 6";
      "cmd-7" = "workspace 7"; "alt-shift-7" = "move-node-to-workspace 7";
      "cmd-8" = "workspace 8"; "alt-shift-8" = "move-node-to-workspace 8";
      "cmd-9" = "workspace 9"; "alt-shift-9" = "move-node-to-workspace 9";
    };

    mode.service.binding = {
      esc       = [ "reload-config" "mode main" ];
      r         = [ "flatten-workspace-tree" "mode main" ];
      f         = [ "layout floating tiling" "mode main" ];
      backspace = [ "close-all-windows-but-current" "mode main" ];
      "cmd-shift-h" = [ "join-with left"  "mode main" ];
      "cmd-shift-j" = [ "join-with down"  "mode main" ];
      "cmd-shift-k" = [ "join-with up"    "mode main" ];
      "cmd-shift-l" = [ "join-with right" "mode main" ];
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
