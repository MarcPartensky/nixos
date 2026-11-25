# services/shorturl-mcp/default.nix
# MCP `shorturl` server for hermes: PUBLIC ANONYMOUS shorteners with
# 4-character domains (x.gd, v.gd, t.tl), code in ./server.py.
#
# Why these three and not a single connector: no public
# shortener combines anonymity, custom slug and reliability, so the server exposes
# a single interface (shorturl_shorten / shorturl_expand / shorturl_history)
# and chooses the backend, with automatic fallback. Details of the criteria and the
# services ruled out (t.ly, s.ee, s.id, 0.gp and its Turnstile fleet, t.im,
# t.mr, l.tl, z.sh, d.to, t.co) in the header of server.py.
#
# No secret: these services are account-less and captcha-less. The only
# local state is the creation log (SHORTURL_STATE_DIR), under hermes's
# home, since none of these services keeps history without an account.
#
# stdio transport: hermes spawns the subprocess. Debug by hand (keep stdin
# open, an EOF kills the request in flight):
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/shorturl-mcp
{self, pkgs, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this config, and no longer rebuilt on each host eval.
  shorturl-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.shorturl-mcp;

in {
  # The binary on the PATH, and referenced by mcpServers.shorturl.command.
  environment.systemPackages = [shorturl-mcp];

}
