# Skins Hermes : pose les YAML du pack « Hermes Menagerie » dans ~/.hermes/skins/,
# dossier que l'engine lit tel quel (hermes_cli/skin_engine.py, lecture seule côté
# Hermes). Le pack est une source brute, pas un flake (flake input
# `hermes-menagerie`, flake = false).
#
# Les fichiers sont des symlinks vers /nix/store, donc read-only : `hermes skin set
# <clé> <hex>` ne peut pas réécrire ces YAML sur place. Pour itérer sur une couleur,
# forker le skin dans un fichier séparé, ou pointer une entrée vers un clone local
# (config.lib.file.mkOutOfStoreSymlink). L'activation reste impérative, config.yaml
# n'étant pas géré par Nix :
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

  # Le pack écrit « catpuccin » (deux p, un seul c) : catpuccin-mocha, catpuccin-latte.
  available = builtins.filter (n: builtins.match ".+\\.yaml" n != null) (
    builtins.attrNames (builtins.readDir packDir)
  );

  selected = if cfg.skins == [ ] then available else map (s: "${s}.yaml") cfg.skins;

  unknown = lib.subtractLists available selected;
in {
  options.my.hermesSkins = {
    enable = lib.mkEnableOption "les skins Hermes Menagerie dans ~/.hermes/skins";

    pack = lib.mkOption {
      type = lib.types.path;
      default = inputs.hermes-menagerie;
      defaultText = lib.literalExpression "inputs.hermes-menagerie";
      description = "Racine du pack (flake input `hermes-menagerie`, flake = false).";
    };

    skins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "catpuccin-mocha" "fox-ember" ];
      description = "Skins à installer (nom sans .yaml) ; vide = tout le pack (26).";
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = ".hermes/skins";
      description = ''
        Dossier des skins, relatif à $HOME. Un profil Hermes utilise
        `.hermes/profiles/<nom>/skins`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknown == [ ];
        message = "my.hermesSkins.skins : skin(s) absent(s) du pack : ${toString unknown}";
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
