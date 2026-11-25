# services/shlink-mcp/default.nix
# Shlink MCP server for hermes (Rust port, crate in ../../mcp/shlink-mcp-rs).
#
# Why a home-made MCP rather than a third-party connector: the REST API v3 of
# Shlink is fully described by an OpenAPI spec, so a passthrough
# (`shlink_request`) is enough to drive everything, plus typed tools for the
# common operations.
#
# Why Rust and no longer Python: same JSON-RPC contract, same 10 tools, same
# responses (parity checked on 9 real calls on 15/11/2026), for 1.4 MB of
# RSS instead of 54 MB, 2 ms startup instead of 4.2 s, and a compact
# response text (1.4 kB instead of 2.4 kB on shlink_list_short_urls).
# The old FastMCP server.py was removed at the same time.
#
# stdio transport: hermes spawns the subprocess. The API key is never
# passed in clear in the config (it is read from the sops file by the
# binary, via SHLINK_API_KEY_FILE).
#
# Writes: SHLINK_ALLOW_WRITES=1 allows them, and each mutating call still
# requires confirm=True; without it the tool returns a preview of the request.
#
# Manual debug (keep stdin open, an EOF kills the request):
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/shlink-mcp-rs
{self, pkgs, config, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this config.
  shlink-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.shlink-mcp;

in {
  # The binary on the PATH.
  environment.systemPackages = [shlink-mcp];

  # stdio declaration: this server is no longer mounted by mcp-host
  # (services.mcp-host.servers no longer lists it), so its tools come back
  # under the mcp__shlink__* namespace instead of hermes-tools.
  services.hermes-agent.mcpServers.shlink = {
    command = "${shlink-mcp}/bin/shlink-mcp-rs";
    args = [];
    env = {
      SHLINK_URL = "http://127.0.0.1:8097";
      SHLINK_API_KEY_FILE = config.sops.secrets.shlink_api_key.path;
      SHLINK_ALLOW_WRITES = "1";
    };
    timeout = 120;
  };
}
