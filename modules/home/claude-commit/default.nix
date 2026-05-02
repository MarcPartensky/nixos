{
  config,
  lib,
  pkgs,
  ...
}: let
  script = pkgs.writeTextFile {
    name = "claude-commit.py";
    text = builtins.readFile ./claude-commit.py;
  };

  claude-commit = pkgs.writeShellScriptBin "claude-commit" ''
    exec ${pkgs.python3}/bin/python3 ${script} "$@"
  '';
in {
  sops.secrets.anthropic_api_key = {
    sopsFile = ../../../secrets/mac.yml;
  };

  home.packages = [claude-commit];
}
