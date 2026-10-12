# services/spotify-mcp/default.nix
# Serveur MCP Spotify (marcelmarais/spotify-mcp-server) lancé en stdio par Hermes sur tower.
#
# flake.nix, dans inputs (remplace l'ancien input varunneal) :
#   spotify-mcp = {
#     url = "github:marcelmarais/spotify-mcp-server/108fd6b26db9bd9627cd4e4a128841a0f8933756";
#     flake = false;
#   };
#
# secrets sops (fichier par défaut) :
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

  # Le projet exige node >= 26.8.1 (package.json, engines).
  nodejs = pkgs.nodejs_26;

  spotify-mcp = pkgs.buildNpmPackage {
    pname = "spotify-mcp-server";
    version = "1.0.0-unstable-2026-09-21";
    src = inputs.spotify-mcp;
    inherit nodejs;

    # 1er build : laisser fakeHash, copier le hash donné par l'erreur, rebuild.
    npmDepsHash = lib.fakeHash;

    # Le chemin de config est codé en dur à côté du build, donc dans le store
    # en lecture seule. On le rend pilotable par variable d'environnement,
    # sinon le refresh du token échoue au bout d'une heure.
    postPatch = ''
      substituteInPlace src/utils.ts \
        --replace-fail \
          "path.join(__dirname, '../spotify-config.json')" \
          "(process.env.SPOTIFY_MCP_CONFIG ?? path.join(__dirname, '../spotify-config.json'))"
    '';

    meta.mainProgram = "spotify-mcp";
  };

  authScript = "${spotify-mcp}/lib/node_modules/spotify-mcp-server/build/auth.js";

  # Le fichier de config contient aussi les tokens, réécrits par le serveur.
  # À chaque lancement on y réinjecte client id / secret depuis sops,
  # en conservant accessToken, refreshToken et expiresAt.
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

  # Login OAuth unique, à lancer à la main en tant que hermes.
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
    # Optionnel, pour démarrer sans les actions destructives :
    # tools.exclude = [ "removeUsersSavedTracks" "unfollowPlaylist" "removeTracksFromPlaylist" ];
  };
}
