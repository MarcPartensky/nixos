{
  config,
  lib,
  ...
}: {
  sops.secrets.gemini_api_key = {
    sopsFile = ../../../secrets/common.yml; # adapte le chemin
  };

  home.activation.geminicommitConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        mkdir -p "${config.home.homeDirectory}/.config/geminicommit"
        echo "[gemini]
    api_key = \"$(cat ${config.sops.secrets.gemini_api_key.path})\"" \
          > "${config.home.homeDirectory}/.config/geminicommit/config.toml"
  '';
}
