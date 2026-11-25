# services/arr-mcp/default.nix
# arr-mcp MCP server (bardesss/arr-mcp): ONE endpoint for the self-hosted
# media stack (Radarr movies, Sonarr series, Prowlarr indexers, Jellyfin).
# Container moved out of the host config: deploy/containers.nix (`arr-mcp` entry,
# migrated = true), podman quadlet `arr-mcp.service`, published on
# 127.0.0.1:6060.
#
# What nix owns:
#   - the container: image, port, /config volume, env file;
#   - the API keys of the four services and the MCP token, in
#     secrets/arr-mcp.yml (recipient = tower only);
#   - the Hermes MCP entry, whose header carries a placeholder
#     ${ARR_MCP_TOKEN}: Hermes resolves it from its environment at the time
#     of connecting, so no secret enters config.yaml or here.
#
# What nix does NOT own: /var/lib/hermes/arr-mcp/config.yaml, the application
# config that the container dashboard rewrites (service URLs, token
# hash, Jellyfin default_user). It carries no secret: the API keys there
# are placeholders ${RADARR_API_KEY} and friends that the container resolves
# from /run/secrets/arr_mcp_env, and the token only appears there hashed (sha256).
{ config, ... }: let
  port = 6060;
in {
  # One sops file, two secrets, because the two consumers do not
  # need the same thing: the container wants the four API keys, hermes
  # only the MCP token (no reason to give it the *arr keys).
  sops.secrets."arr_mcp_env" = {
    sopsFile = ../../secrets/arr-mcp.yml;
    owner = "hermes";
  };
  sops.secrets."hermes_arr_mcp_env" = {
    sopsFile = ../../secrets/arr-mcp.yml;
    owner = "hermes";
  };

  # environmentFiles is concatenated into $HERMES_HOME/.env: it is from there that
  # Hermes reads ${ARR_MCP_TOKEN} for the header below.
  services.hermes-agent.environmentFiles = [
    config.sops.secrets."hermes_arr_mcp_env".path
  ];

  # The URL goes through the LAN redirector of services/mcp-lan-access to be
  # clickable from Hermes Desktop on the Mac; on the tower side, local traffic
  # goes back through lo.
  services.hermes-agent.mcpServers.arrmcp = {
    url =
      if config.services.mcp-lan-access.enable
      then "http://${config.services.mcp-lan-access.host}:${toString port}/mcp"
      else "http://127.0.0.1:${toString port}/mcp";
    # \${...}: the placeholder must arrive LITERALLY in config.yaml,
    # it is Hermes that resolves it on connection (MCP doc: ${VAR} in url and
    # headers, read from the process environment).
    headers.Authorization = "Bearer \${ARR_MCP_TOKEN}";
    timeout = 120;
  };
}
