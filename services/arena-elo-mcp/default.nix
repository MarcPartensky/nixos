# services/arena-elo-mcp/default.nix
# `arena-elo` MCP server for hermes: Arena's Elo rankings (ex-LMArena,
# ex-Chatbot Arena) WITHOUT AUTHENTICATION, code in ./arena-elo.py.
#
# Single source: the public dataset lmarena-ai/leaderboard-dataset on
# Hugging Face (CC BY 4.0), read via the public datasets-server API. No key,
# no account: the scores are Bradley-Terry fits of blind human votes,
# displayed on Arena's Elo scale with a 95% interval.
#
# Why this detour through the dataset: arena.ai exposes neither MCP nor a public API
# and its leaderboard page returns 403 to non-browser clients; the
# /filter endpoint of datasets-server requires auth for any WHERE on a
# text column. So we page /rows (5-6 pages per board) and cache to disk for 6 h
# under ARENA_ELO_CACHE. The rows arrive grouped by category and sorted by
# rank, which lets us stop as soon as a page adds nothing more.
#
# The history is LOCAL by construction: the upstream "full" split has 1.1 M
# rows for text, impossible to page anonymously. Each published
# snapshot is logged once (history.jsonl) when the board is read,
# so the series starts at the first call and grows with each update.
#
# The server speaks JSON-RPC 2.0 over stdio itself (stdlib only, no
# mcp SDK): stdin line by line, stdout reserved for the protocol, logs on stderr.
{self, pkgs, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this config, and no longer rebuilt on every host eval.
  arena-elo-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.arena-elo-mcp;
in {
  environment.systemPackages = [arena-elo-mcp];

  services.hermes-agent.mcpServers.arena-elo = {
    command = "${arena-elo-mcp}/bin/arena-elo-mcp";
    args = [];
    env = {
      ARENA_ELO_CACHE = "/var/lib/hermes/.hermes/cache/arena-elo";
    };
    # A cold board costs 5-6 pages spaced 0.5 s apart; arena=all scans six of them.
    timeout = 180;
  };
}