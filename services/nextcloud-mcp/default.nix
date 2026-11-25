# services/nextcloud-mcp/default.nix
# Nextcloud MCP server (cbcoutinho/nextcloud-mcp-server) in single_user_basic mode,
# exposed as streamable-http on loopback; Hermes connects to it over HTTP.
#
# Auth: Nextcloud app password (Settings -> Security -> Devices
# & sessions), not the login password. Docs: docs/authentication.md in the repo.
#
# Sops secret (secrets/tower.yml):
#   nextcloud_mcp_env: |
#     NEXTCLOUD_USERNAME=your_user
#     NEXTCLOUD_PASSWORD=your_app_password
#
# Debug:
#   journalctl -u podman-nextcloud-mcp.service -f   (or docker- depending on the backend)
#   curl http://127.0.0.1:8710/health/ready
{config, ...}: let
  port = 8710;
in {
  # Container moved out of the host config: deploy/containers.nix (entry
  # `nextcloud-mcp`, migrated = true), podman quadlet
  # `nextcloud-mcp.service`. network=host and the --host 127.0.0.1 cmd are
  # carried over identically; the environment file remains the sops secret
  # below, read by the quadlet (/run/secrets/nextcloud_mcp_env).
  # Takeover: `just deploy nextcloud-mcp --takeover` BEFORE the switch that
  # removes this block.

  # The secret stays declared here: that is what makes it available to the
  # quadlet. restartUnits targets the quadlet name (no more podman-*.service).
  #
  # owner/mode: the quadlet runs ROOTLESS under the hermes user, so
  # the file must belong to it. With the sops default (root:root 0400), the
  # container starts without an environment and the unit loops (observed: the file
  # was unreadable by hermes while it worked in rootful). No other
  # root consumer reads it since the oci-containers block is gone.
  sops.secrets."nextcloud_mcp_env" = {
    owner = "hermes";
    mode = "0400";
    restartUnits = ["nextcloud-mcp.service"];
  };

  # Hermes: HTTP transport to the loopback container.
  # The tools appear prefixed mcp_nextcloud_* when hermes starts.
  # LAN URL (module services/mcp-lan-access): reachable from tower (traffic
  # local via lo) and clickable from Hermes Desktop on marc's Mac.
  services.hermes-agent.mcpServers.nextcloud.url =
    if config.services.mcp-lan-access.enable
    then "http://${config.services.mcp-lan-access.host}:${toString port}/mcp"
    else "http://127.0.0.1:${toString port}/mcp";
}
