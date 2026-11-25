# services/spotify-mcp/default.nix
# Spotify MCP server (marcelmarais/spotify-mcp-server) launched in stdio by Hermes on tower.
#
# flake.nix, in inputs (replaces the old varunneal input):
#   spotify-mcp = {
#     url = "github:marcelmarais/spotify-mcp-server/108fd6b26db9bd9627cd4e4a128841a0f8933756";
#     flake = false;
#   };
#
# sops secrets (default file):
#   spotify_mcp_env: |
#     SPOTIFY_CLIENT_ID=...
#     SPOTIFY_CLIENT_SECRET=...
#
# App Spotify Developer : redirect URI = http://127.0.0.1:8888/callback
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  stateDir = "/var/lib/hermes/spotify-mcp";
  configFile = "${stateDir}/spotify-config.json";
  redirectUri = "http://127.0.0.1:8888/callback";

  # The project requires node >= 26.8.1 (package.json, engines).
  nodejs = pkgs.nodejs_26;

  spotify-mcp = pkgs.buildNpmPackage {
    pname = "spotify-mcp-server";
    version = "1.0.0-unstable-2026-09-21";
    src = inputs.spotify-mcp;
    inherit nodejs;

    # 1st build: leave fakeHash, copy the hash given by the error, rebuild.
    npmDepsHash = lib.fakeHash;

    # The config path is hardcoded next to the build, so in the read-only
    # store. We make it controllable via an environment variable,
    # otherwise the token refresh fails after an hour.
    postPatch = ''
      substituteInPlace src/utils.ts \
        --replace-fail \
          "path.join(__dirname, '../spotify-config.json')" \
          "(process.env.SPOTIFY_MCP_CONFIG ?? path.join(__dirname, '../spotify-config.json'))"
    '';

    meta.mainProgram = "spotify-mcp";
  };

  authScript = "${spotify-mcp}/lib/node_modules/spotify-mcp-server/build/auth.js";

  # The config file also contains the tokens, rewritten by the server.
  # On each launch we reinject client id / secret from sops into it,
  # keeping accessToken, refreshToken and expiresAt.
  prepareConfig = ''
    set -euo pipefail
    umask 077
    set -a
    . ${config.sops.secrets.spotify_mcp_env.path}
    set +a
    [ -f ${configFile} ] || echo '{}' > ${configFile}
    ${lib.getExe pkgs.jq} \
      --arg id "$SPOTIFY_CLIENT_ID" \
      --arg secret "$SPOTIFY_CLIENT_SECRET" \
      --arg uri ${redirectUri} \
      '. + {clientId: $id, clientSecret: $secret, redirectUri: $uri}' \
      ${configFile} > ${configFile}.tmp
    mv ${configFile}.tmp ${configFile}
    export SPOTIFY_MCP_CONFIG=${configFile}
  '';

  wrapper = pkgs.writeShellScript "spotify-mcp-hermes" ''
    ${prepareConfig}
    exec ${lib.getExe spotify-mcp}
  '';

  # One-time OAuth login, to launch by hand as hermes.
  login = pkgs.writeShellScriptBin "spotify-mcp-login" ''
    ${prepareConfig}
    exec ${lib.getExe nodejs} ${authScript}
  '';
in {
  sops.secrets.spotify_mcp_env = {
    owner = "hermes";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 hermes hermes -"
  ];

  environment.systemPackages = [login];

  services.hermes-agent.mcpServers.spotify = {
    command = "${wrapper}";
    # Optional, to start without the destructive actions:
    # tools.exclude = [ "removeUsersSavedTracks" "unfollowPlaylist" "removeTracksFromPlaylist" ];
  };
}
