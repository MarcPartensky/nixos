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
    # Hash base32 nix-prefetch-url -> SRI : depuis Nix 2.x un hash nu n'a plus
    # de type et fait échouer TOUTE l'évaluation de la config tower.
    hash = "sha256-ElfVEkftD02XHQ6Cu6viaIRvSuw+kFvvmGzvzUPnnb4=";
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
