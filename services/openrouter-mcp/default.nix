# services/openrouter-mcp/default.nix
# Serveur MCP OpenRouter (codeChap/mcp-server-open-router) pour hermes.
#
# 5 outils : chat, chat_with_vision, chat_with_search (recherche web via le
# plugin OpenRouter), list_models, credits. Binaire Rust unique, stdio.
# Choisi plutôt que le serveur officiel distant (mcp.openrouter.ai, OAuth) :
# ce dernier délivre une clé à durée de vie 7 jours (spend cap $10), donc
# inutilisable pour une intégration nix déclarative "pose et oublie".
#
# Le binaire lit sa config depuis $XDG_CONFIG_HOME/mcp-server-open-router/config.toml
# (crate `dirs`, pas de variable d'env ni de flag pour le chemin). Le wrapper
# régénère ce fichier à chaque lancement depuis le secret sops : la clé n'est
# JAMAIS en clair dans le nix store ni dans mcpServers.env.
#
# Secret : secrets/openrouter-mcp.yml (sops, clé openrouter_api_key).
# PLACEHOLDER à remplacer par marc :
#   nix run nixpkgs#sops -- secrets/openrouter-mcp.yml
# (clé OpenRouter : https://openrouter.ai/settings/keys)
{
  config,
  lib,
  pkgs,
  ...
}: let
  version = "unstable-2026-09-28";
  src = pkgs.fetchFromGitHub {
    owner = "codeChap";
    repo = "mcp-server-open-router";
    rev = "f6952c1053121b3a02c87c5f5c7c21f7517445d0";
    hash = "sha256-rlck7hpyRxwAB+/kR+2eeuOCbmceTMzTvuCqS0kTEV0=";
  };

  openrouter-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "mcp-server-open-router";
    inherit version src;
    cargoLock.lockFile = "${src}/Cargo.lock";
    # reqwest -> openssl-sys a besoin de pkg-config + libs de dev OpenSSL.
    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    meta = {
      description = "MCP server for OpenRouter (chat, vision, web search, model list, credits)";
      homepage = "https://github.com/codeChap/mcp-server-open-router";
      license = lib.licenses.mit;
      mainProgram = "open-router";
    };
  };

  stateDir = "/var/lib/hermes/openrouter-mcp";
  configDir = "${stateDir}/config";
  apiKeyFile = config.sops.secrets."openrouter-mcp/api_key".path;

  # Régénère config.toml à chaque lancement depuis le secret sops (jq -Rs
  # produit une chaîne TOML/JSON correctement échappée, jamais d'interpolation
  # brute d'une valeur pouvant contenir des guillemets).
  wrapper = pkgs.writeShellScript "openrouter-mcp-hermes" ''
    set -euo pipefail
    umask 077
    mkdir -p ${configDir}/mcp-server-open-router
    key_json=$(printf '%s' "$(cat ${apiKeyFile})" | ${lib.getExe pkgs.jq} -Rs .)
    printf 'api_key = %s\n' "$key_json" > ${configDir}/mcp-server-open-router/config.toml
    export XDG_CONFIG_HOME=${configDir}
    exec ${lib.getExe openrouter-mcp}
  '';
in {
  sops.secrets."openrouter-mcp/api_key" = {
    key = "openrouter_api_key";
    sopsFile = ../../secrets/openrouter-mcp.yml;
    owner = "hermes";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 hermes hermes -"
  ];

  services.hermes-agent.mcpServers.openrouter = {
    command = "${wrapper}";
    timeout = 60;
  };
}
