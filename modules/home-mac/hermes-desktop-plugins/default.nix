# Hermes desktop plugins: places `plugin.js` into the renderer's "disk door"
# of Desktop, <HERMES_HOME>/desktop-plugins/<name>/plugin.js.
#
# A desktop plugin extends the APP (panes, settings pages, themes), not an agent:
# it lives on the app's machine side (the Mac) even when the session runs on a remote
# backend (SSH to tower). The loader always resolves the app's LOCAL home, and
# scans the folder while watching it: a file dropped there loads hot, without
# a restart.
#
# Nothing other than plugin.js is required: the inventory (name, description,
# capabilities) comes from the default-export of the JS module, not from a plugin.yaml.
#
# NOT DECLARABLE: a plugin's activation (enable/disable) and settings
# (ctx.storage) live in the renderer's localStorage, not in a file.
# A plugin with no recorded decision activates by default, hence the interest of
# setting the plugin's default values here rather than relying on a click.
{ lib, config, ... }:
let
  cfg = config.my.hermesDesktopPlugins;
in {
  options.my.hermesDesktopPlugins = {
    enable = lib.mkEnableOption "Hermes desktop plugins (~/.hermes/desktop-plugins)";

    dir = lib.mkOption {
      type = lib.types.str;
      default = ".hermes/desktop-plugins";
      description = "Desktop plugins folder, relative to $HOME.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = { claude-code-theme = ./plugin.js; };
      description = "One plugin.js per entry (folder name -> JS file).";
    };
  };

  config = lib.mkIf cfg.enable {
    # force = true: the plugin may already exist as a real file (installed from
    # the app, or copied to test live); the switch takes over it.
    home.file = lib.mapAttrs' (name: src: {
      name = "${cfg.dir}/${name}/plugin.js";
      value = {
        source = src;
        force = true;
      };
    }) cfg.plugins;
  };
}
