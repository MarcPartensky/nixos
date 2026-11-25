# services/sherlock-mcp/default.nix
# `username-recon` MCP for hermes: enumerates the public accounts of a username
# or an email, code in ./server.py.
#
# One server per CAPABILITY, not one server per tool: the three engines
# (sherlock 414 sites, maigret 3155 sites with profile parsing, socialscan
# 11 platforms by probing the signup endpoints) are behind a single
# set of tools, and the engine choice is a server decision (`engines=auto`
# does sherlock then switches, `engines=all` does the union), not a reasoning to
# redo on each conversation.
#
# What the server adds to the bare engines: NEGATIVE CONTROL. Each engine
# is re-run with an impossible username, and any site that declares it existing
# is marked `unreliable` instead of being presented as a hit. This is the answer
# to Sherlock's structural flaw (a site that answers 200 to everything is announced
# "Claimed" for anything). Measurement of 2026-11-11: 5 noisy sites for
# sherlock, 13 for maigret, on a random username. The result is cached
# under SHERLOCK_MCP_STATE (TTL 72 h): a full pass costs 1 to 2 minutes,
# we do not redo it on each scan.
#
# The binary embeds the engines in its PATH and the state under /var/lib/hermes
# (ProtectSystem=strict: an MCP subprocess can only write there). The state
# also includes a writable copy of the maigret database: the
# nixpkgs package rewrites its database on exit and dies with PermissionError on the store.
#
# Manual debug (keep stdin open, an EOF kills the in-flight request):
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/username-recon-hermes
{self, pkgs, lib, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this config, and no longer rebuilt on each host eval.
  username-recon = self.packages.${pkgs.stdenv.hostPlatform.system}.username-recon;

  wrapper = pkgs.writeShellScript "username-recon-hermes" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [pkgs.sherlock pkgs.maigret pkgs.socialscan]
    }:$PATH
    export SHERLOCK_MCP_STATE=/var/lib/hermes/.hermes/cache/username-recon
    exec ${username-recon}/bin/username-recon
  '';
in {
  environment.systemPackages = [username-recon];

  services.hermes-agent.mcpServers.username-recon = {
    command = "${wrapper}";
    args = [];
    # A full sherlock sweep takes 60 to 90 s, maigret about 1 min, and a
    # scan `engines=all` with a cold negative control reaches 2 to 3 min.
    timeout = 900;
  };
}
