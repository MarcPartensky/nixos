{
  config,
  lib,
  ...
}: let
  cfgDir = "${config.home.homeDirectory}/.config/geminicommit";
  cfgFile = "${cfgDir}/config.toml";
in {
  sops.secrets.gemini_api_key = {
    sopsFile = ../../../secrets/common.yml;
  };

  home.activation.geminicommitConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    secret=${lib.escapeShellArg config.sops.secrets.gemini_api_key.path}
    if [ -r "$secret" ]; then
      mkdir -p ${lib.escapeShellArg cfgDir}
      umask 077
      printf '[api]\nkey = "%s"\n' "$(cat "$secret")" > ${lib.escapeShellArg cfgFile}
    else
      echo "geminicommit: secret illisible ($secret), config non ecrite" >&2
    fi
  '';
}
