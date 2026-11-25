# services/openrouter-mcp/default.nix
# OpenRouter MCP server (codeChap/mcp-server-open-router) for hermes.
#
# 5 tools: chat, chat_with_vision, chat_with_search (web search via the
# OpenRouter plugin), list_models, credits. Single Rust binary, stdio.
# Chosen over the official remote server (mcp.openrouter.ai, OAuth):
# the latter issues a key with a 7-day lifetime (spend cap $10), so
# unusable for a declarative nix "set and forget" integration.
#
# The binary reads its config from $XDG_CONFIG_HOME/mcp-server-open-router/config.toml
# (crate `dirs`, no env var and no flag for the path). The wrapper
# regenerates this file on every launch from the sops secret: the key is
# NEVER in cleartext in the nix store nor in mcpServers.env.
#
# Secret: secrets/openrouter-mcp.yml (sops, key openrouter_api_key).
# PLACEHOLDER to be replaced by marc:
#   nix run nixpkgs#sops -- secrets/openrouter-mcp.yml
# (OpenRouter key: https://openrouter.ai/settings/keys)
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
    # reqwest -> openssl-sys needs pkg-config + OpenSSL dev libs.
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

  # Regenerates config.toml on every launch from the sops secret (jq -Rs
  # produces a correctly escaped TOML/JSON string, never a raw
  # interpolation of a value that may contain quotes).
  wrapper = pkgs.writeShellScript "openrouter-mcp-hermes" ''
    set -euo pipefail
    umask 077
    mkdir -p ${configDir}/mcp-server-open-router
    key_json=$(printf '%s' "$(cat ${apiKeyFile})" | ${lib.getExe pkgs.jq} -Rs .)
    printf 'api_key = %s\n' "$key_json" > ${configDir}/mcp-server-open-router/config.toml
    printf 'default_model = "%s"\n' "nvidia/nemotron-3-ultra-550b-a55b:free" >> ${configDir}/mcp-server-open-router/config.toml
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
