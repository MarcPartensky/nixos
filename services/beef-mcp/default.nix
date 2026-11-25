# services/beef-mcp/default.nix
# BeEF MCP server for hermes (code in ./server.py).
#
# Why a homegrown MCP: BeEF only has a web console, with no API client. The
# services/beef module gives it a deterministic REST API token (patch of
# core/main/crypto.rb + sops secret), which lets this server drive the
# console over stdio: list hooked browsers, search for a module,
# run it on a session, read the result.
#
# stdio transport: hermes spawns the subprocess. The token is never passed in
# clear in the config (re-read on every call from the sops file, via
# BEEF_API_TOKEN_FILE); the secret is 0440 beef:hermes, so readable by the
# beef service (owner) and by the MCP (group hermes).
#
# The two tools that execute code in the victim's browser
# (beef_run_module, beef_unhook) require confirm=True; without it they return
# the preview of the submission.
#
# Manual debug (keep stdin open, an EOF kills the request):
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/beef-mcp
{self, pkgs, config, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this conf, and no longer rebuilt on every host eval.
  beef-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.beef-mcp;

in {
  # The binary on the PATH, referenced by mcpServers.beef.command.
  environment.systemPackages = [beef-mcp];

}
