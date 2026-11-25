# services/mcp-nixos/default.nix
# NixOS MCP server (utensils/mcp-nixos, pkgs.mcp-nixos in nixpkgs 26.05).
# Used to query the REAL NixOS data instead of making it up:
# packages (130k+), NixOS options (23k+), home-manager options, nix-darwin,
# nixvim, NVF, FlakeHub, Noogle, NixOS wiki.
# Queries public APIs (search.nixos.org, etc.): no secret required.
{ pkgs, ... }:
{
  services.hermes-agent.mcpServers.nixos = {
    command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
    env = {
      MCP_NIXOS_TRANSPORT = "stdio";
    };
  };
}
