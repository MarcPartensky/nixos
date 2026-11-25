# services/meetup-mcp/default.nix
# Meetup MCP server for hermes: search of public events and groups
# via the Meetup GraphQL API (https://api.meetup.com/gql-ext), transport
# stdio (hermes spawns the subprocess, no systemd unit).
#
# Auth: NONE required for this scope. Verified on 26/09/2026 without a token:
# eventSearch, groupSearch, event, events, groupByUrlname, recommendedEvents,
# recommendedGroups, suggestTopics, topicCategories all respond. The
# named queries (self, personal RSVPs, event publishing) require
# an OAuth consumer, which only a Meetup Pro account can create. If a token
# ever arrives: put it in secrets/meetup.yml (key meetup_oauth_token),
# declare it in sops.secrets here (owner/group hermes, mode 0400,
# restartUnits hermes-agent) and the server will read it via MEETUP_TOKEN_FILE,
# with no code change (file absent = public mode).
#
# The server code lives in meetup_mcp.py alongside (testable in isolation);
# writers.writePython3Bin lints it (pycodestyle/pyflakes) at build time.
#
# Debug: { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#   | /nix/store/.../bin/meetup-mcp   (keep stdin open: an EOF kills the request)
{self, pkgs, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this config, and no longer rebuilt on every host eval.
  meetup-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.meetup-mcp;
in {
}
