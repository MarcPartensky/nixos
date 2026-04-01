{
  config,
  pkgs,
  ...
}: let
  musicPath = "${config.home.homeDirectory}/media/music/ytui-music";

  # On crée UNIQUEMENT le binaire "ytui"
  # Il va appeler le binaire original avec les bons paramètres
  ytui-script = pkgs.writeShellScriptBin "ytui" ''
    export YTUI_MUSIC_DIR="${musicPath}"
    mkdir -p "${musicPath}"
    # On lance la version originale avec 'run' par défaut
    exec ${pkgs.ytui-music}/bin/ytui_music run "$@"
  '';

  conf = {
    # Ta config JSON complète ici
    Colors = {
      border_idle = [100 100 100];
      border_highlight = [0 255 127];
      list_idle = [200 200 200];
      list_hilight = [0 255 255];
      sidebar_list = [150 150 150];
      block_title = [255 255 0];
      gauge_fill = [0 255 0];
      color_primary = [255 255 255];
      color_secondary = [180 180 180];
      status_text = [255 255 255];
    };
    Servers.list = ["https://invidious.snopyta.org" "https://yewtu.be"];
    Downloads.path = musicPath;
  };
in {
  # 1. On installe le binaire original ET notre raccourci "ytui"
  # Home Manager va fusionner les deux sans râler car les noms de fichiers sont différents
  home.packages = [
    pkgs.ytui-music
    ytui-script
  ];

  # 2. On s'assure que le JSON est là
  xdg.configFile.".ytui-music/config.json".text = builtins.toJSON conf;
  xdg.configFile."config.json".text = builtins.toJSON conf;

  # 3. Optionnel : On définit la variable globalement pour le binaire original aussi
  home.sessionVariables = {
    YTUI_MUSIC_DIR = musicPath;
  };
}
