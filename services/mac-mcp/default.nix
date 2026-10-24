# services/mac-mcp/default.nix
# Serveur MCP "mac" : pilote le Mac de marc depuis l'hote de l'agent, en ssh
# (build Winnie macOS + iOS, etat du poste, sync du depot, operations root
# Xcode via la regle sudo NOPASSWD). Le script vit dans ./mac-mcp.py ; hote
# ssh choisi au premier appel : alias maclan (LAN) puis mac (tunnel inverse
# par rack), cle id_ed25519 de hermes. Contexte : skill marc-mac-operations.
{pkgs, ...}: let
  mac-mcp = pkgs.writers.writePython3Bin "mac-mcp" {
    libraries = [pkgs.python3Packages.mcp];
  } (builtins.readFile ./mac-mcp.py);
in {
  services.hermes-agent.mcpServers.mac = {
    command = "${mac-mcp}/bin/mac-mcp";
    timeout = 1800;
  };
}
