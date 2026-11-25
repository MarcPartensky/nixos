# services/mac-mcp/default.nix
# MCP server "mac": drives marc's Mac from the agent host, over ssh
# (Winnie macOS + iOS build, workstation state, repo sync, root
# Xcode operations via the sudo NOPASSWD rule). The script lives in ./mac-mcp.py; the ssh
# host is chosen on the first call: alias maclan (LAN) then mac (reverse tunnel
# via rack), hermes' id_ed25519 key. Context: skill marc-mac-operations.
{self, pkgs, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this conf, and no longer rebuilt on every host eval.
  mac-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.mac-mcp;
in {
}
