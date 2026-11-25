# Plugins desktop Hermes : pose des `plugin.js` dans le « disk door » du renderer
# Desktop, <HERMES_HOME>/desktop-plugins/<nom>/plugin.js.
#
# Un plugin desktop étend l'APP (panes, pages de réglages, thèmes), pas un agent :
# il vit côté machine de l'app (le Mac) même quand la session tourne sur un backend
# distant (SSH vers tower). Le loader résout toujours le home LOCAL de l'app, et
# scanne le dossier en le surveillant : un fichier posé là se charge à chaud, sans
# redémarrage.
#
# Rien d'autre que plugin.js n'est requis : l'inventaire (nom, description,
# capacités) vient du default-export du module JS, pas d'un plugin.yaml.
#
# NON DÉCLARABLE : l'activation (enable/disable) et les réglages d'un plugin
# (ctx.storage) vivent dans le localStorage du renderer, pas dans un fichier.
# Un plugin sans décision enregistrée s'active par défaut, d'où l'intérêt de
# poser ici les valeurs par défaut du plugin plutôt que de compter sur un clic.
{ lib, config, ... }:
let
  cfg = config.my.hermesDesktopPlugins;
in {
  options.my.hermesDesktopPlugins = {
    enable = lib.mkEnableOption "les plugins desktop Hermes (~/.hermes/desktop-plugins)";

    dir = lib.mkOption {
      type = lib.types.str;
      default = ".hermes/desktop-plugins";
      description = "Dossier des plugins desktop, relatif à $HOME.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = { claude-code-theme = ./plugin.js; };
      description = "Un plugin.js par entrée (nom du dossier -> fichier JS).";
    };
  };

  config = lib.mkIf cfg.enable {
    # force = true : le plugin peut déjà exister en fichier réel (install depuis
    # l'app, ou copie pour tester à chaud) ; le switch reprend la main dessus.
    home.file = lib.mapAttrs' (name: src: {
      name = "${cfg.dir}/${name}/plugin.js";
      value = {
        source = src;
        force = true;
      };
    }) cfg.plugins;
  };
}
