{
  config,
  pkgs,
  ...
}: let
  musicPath = "${config.home.homeDirectory}/media/music/ytui-music";

  # We create ONLY the "ytui" binary
  # It will call the original binary with the right parameters
  ytui-script = pkgs.writeShellScriptBin "ytui" ''
    export YTUI_MUSIC_DIR="${musicPath}"
    mkdir -p "${musicPath}"
    # We launch the original version with 'run' by default
    exec ${pkgs.ytui-music}/bin/ytui_music run "$@"
  '';

  conf = {
    # Your full JSON config here
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
  # 1. We install the original binary AND our "ytui" shortcut
  # Home Manager will merge the two without complaining since the file names are different
  home.packages = [
    pkgs.ytui-music
    ytui-script
  ];

  # 2. We make sure the JSON is there
  xdg.configFile.".ytui-music/config.json".text = builtins.toJSON conf;
  xdg.configFile."config.json".text = builtins.toJSON conf;

  # 3. Optional: We define the variable globally for the original binary too
  home.sessionVariables = {
    YTUI_MUSIC_DIR = musicPath;
  };
}
