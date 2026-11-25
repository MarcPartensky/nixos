# Home Manager module for typer-race config file.
#
# Generates ~/.config/typer-race/config.yml (Linux) or
# ~/Library/Application Support/typer-race/config.yml (macOS).
#
# Usage:
#   inputs.typer = { url = "path:./projects/typer"; inputs.nixpkgs.follows = "nixpkgs"; };
#   home-manager.modules = [ inputs.typer.homeManagerModules.default ];
#   programs.typer-race = {
#     enable = true;
#     url = "ws://100.64.0.4:9146/ws";
#     name = "marc";
#     lang = "english200";
#     time = 30;
#     ui = "en";
#   };
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.typer-race;

  # Build YAML content as a single string
  yamlContent = ''
    url: "${cfg.url}"
    ${lib.optionalString (cfg.room != "") "room: \"${cfg.room}\""}
    name: "${cfg.name}"
    lang: "${cfg.lang}"
    time: ${toString cfg.time}
    ui: "${cfg.ui}"
  '';

  configDir = if pkgs.stdenv.isDarwin
    then "${config.home.homeDirectory}/Library/Application Support/typer-race"
    else "${config.xdg.configHome}/typer-race";

  configFile = "${configDir}/config.yml";
in {
  options.programs.typer-race = {
    enable = lib.mkEnableOption "typer-race terminal client config file";

    url = lib.mkOption {
      type = lib.types.str;
      default = "ws://127.0.0.1:9146/ws";
      description = "WebSocket URL for the typer race server";
    };

    room = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Room code to join (empty = create new)";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = config.home.username;
      description = "Player name";
    };

    lang = lib.mkOption {
      type = lib.types.enum [ "english200" "english1000" "french200" "french1000" ];
      default = "english200";
      description = "Word list";
    };

    time = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Race duration in seconds";
    };

    ui = lib.mkOption {
      type = lib.types.enum [ "fr" "en" ];
      default = "en";
      description = "UI language";
    };
  };

  config = lib.mkIf cfg.enable {
    # Use home.file which handles directory creation and spaces in paths
    home.file."typer-race-config.yml" = {
      text = yamlContent;
      target = configFile;
    };
  };
}