# services/mac-mcp/default.nix
# Serveur MCP "mac" : pilote le Mac de marc depuis l'hote de l'agent, en ssh
# (build Winnie macOS + iOS, etat du poste, sync du depot, operations root
# Xcode via la regle sudo NOPASSWD). Le script vit dans ./mac-mcp.py ; hote
# ssh choisi au premier appel : alias maclan (LAN) puis mac (tunnel inverse
# par rack), cle id_ed25519 de hermes. Contexte : skill marc-mac-operations.
{self, pkgs, ...}: let
  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf, et plus reconstruit a chaque eval de l'hote.
  mac-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.mac-mcp;
in {
}
