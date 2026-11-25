# Hermes skins: places the YAML of the "Hermes Menagerie" pack in ~/.hermes/skins/,
# a directory the engine reads as-is (hermes_cli/skin_engine.py, read-only on the
# Hermes side). The pack is a raw source, not a flake (flake input
# `hermes-menagerie`, flake = false).
#
# The files are symlinks to /nix/store, hence read-only: `hermes skin set
# <key> <hex>` cannot rewrite these YAML in place. To iterate on a color,
# fork the skin into a separate file, or point an entry to a local clone
# (config.lib.file.mkOutOfStoreSymlink). Activation remains imperative, config.yaml
# not being managed by Nix:
#   hermes config set display.skin catpuccin-mocha
{
  lib,
  config,
  inputs,
  ...
}:
let
  cfg = config.my.hermesSkins;

  packDir = cfg.pack + "/skins";

  # The pack spells "catpuccin" (two p, one c): catpuccin-mocha, catpuccin-latte.
  available = builtins.filter (n: builtins.match ".+\\.yaml" n != null) (
    builtins.attrNames (builtins.readDir packDir)
  );

  selected = if cfg.skins == [ ] then available else map (s: "${s}.yaml") cfg.skins;

  unknown = lib.subtractLists available selected;
in {
  options.my.hermesSkins = {
    enable = lib.mkEnableOption "the Hermes Menagerie skins in ~/.hermes/skins";

    pack = lib.mkOption {
      type = lib.types.path;
      default = inputs.hermes-menagerie;
      defaultText = lib.literalExpression "inputs.hermes-menagerie";
      description = "Root of the pack (flake input `hermes-menagerie`, flake = false).";
    };

    skins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "catpuccin-mocha" "fox-ember" ];
      description = "Skins to install (name without .yaml); empty = the whole pack (26).";
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = ".hermes/skins";
      description = ''
        Skins directory, relative to $HOME. A Hermes profile uses
        `.hermes/profiles/<name>/skins`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknown == [ ];
        message = "my.hermesSkins.skins: skin(s) missing from the pack: ${toString unknown}";
      }
    ];

    home.file = builtins.listToAttrs (
      map (f: {
        name = "${cfg.dir}/${f}";
        value.source = packDir + "/${f}";
      }) selected
    );
  };
}
