# services/mcp-nixos/default.nix
# Serveur MCP NixOS (utensils/mcp-nixos, pkgs.mcp-nixos dans nixpkgs 26.05).
# Sert à interroger les VRAIES données NixOS au lieu de les inventer :
# packages (130k+), options NixOS (23k+), options home-manager, nix-darwin,
# nixvim, NVF, FlakeHub, Noogle, wiki NixOS.
# Interroge les API publiques (search.nixos.org, etc.) : aucun secret requis.
{ pkgs, ... }:
{
  services.hermes-agent.mcpServers.nixos = {
    command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
    env = {
      MCP_NIXOS_TRANSPORT = "stdio";
    };
  };
}
