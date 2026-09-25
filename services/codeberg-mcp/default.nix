# services/codeberg-mcp/default.nix
# Serveur MCP Codeberg (effecet/codeberg-mcp) : 49 outils.
# Le package est créé ici ; le mcpServers est configuré dans services/hermes/default.nix.
{ pkgs, lib, ... }:
let
  python = pkgs.python312;
  srcRepo = pkgs.fetchFromGitHub {
    owner = "effecet";
    repo = "codeberg-mcp";
    rev = "f7e2fa06ca097cfa5638cef3768c35072c554fd9";
    # Hash temporaire — à corriger avec nix-prefetch-github après build.
    hash = "1glxwx1wvvvck3pmp41yxi56z138wamvp0hf3nbls3zd8w9damqj";
  };
  # Package Python manuel : le repo n'a pas de build-system valide.
  # On crée un binaire qui lance server.py avec le bon python.
  codeberg-mcp-bin = pkgs.writeShellScriptBin "codeberg-mcp" ''
    exec ${python.interpreter} ${srcRepo}/server.py "$@"
  '';
in {
  # Le binaire est disponible sur le PATH.
  environment.systemPackages = [ codeberg-mcp-bin ];

  services.hermes-agent.mcpServers.codeberg = {
    command = "${codeberg-mcp-bin}/bin/codeberg-mcp";
    env = {
      # Remplacer par le JSON du token Codeberg.
      CODEBERG_ACCOUNTS = "{\"default\": \"tok_PLACEHOLDER\"}";
      MCP_TRANSPORT = "stdio";
    };
    timeout = 60;
  };
}
