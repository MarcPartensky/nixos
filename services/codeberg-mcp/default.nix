# services/codeberg-mcp/default.nix
# Serveur MCP Codeberg (effecet/codeberg-mcp) : 49 outils.
# Le package est créé ici ; le mcpServers est configuré dans
# services/hermes/default.nix (ou ici, l'option est la même).
#
# Le token Codeberg n'est JAMAIS en clair dans le nix store : il vit dans
# secrets/codeberg.yml (sops), est injecté dans un .env généré (sops.templates),
# et le wrapper le "source" avant d'exec le serveur.
# Créer le token : https://codeberg.org/user/settings/applications
# (scopes read/write:repository, read/write:issue, read:user).
{
  pkgs,
  lib,
  config,
  ...
}: let
  python = pkgs.python312;
  srcRepo = pkgs.fetchFromGitHub {
    owner = "effecet";
    repo = "codeberg-mcp";
    rev = "f7e2fa06ca097cfa5638cef3768c35072c554fd9";
    # Hash base32 nix-prefetch-url -> SRI : depuis Nix 2.x un hash nu n'a plus
    # de type et fait échouer TOUTE l'évaluation de la config tower.
    hash = "sha256-ElfVEkftD02XHQ6Cu6viaIRvSuw+kFvvmGzvzUPnnb4=";
  };

  # .env généré depuis sops (contient CODEBERG_ACCOUNTS avec le vrai token),
  # lisible par hermes uniquement.
  envFile = config.sops.templates."codeberg-mcp.env".path;

  # Package Python manuel : le repo n'a pas de build-system valide.
  # Le wrapper "source" le .env sops puis lance server.py.
  codeberg-mcp-bin = pkgs.writeShellScriptBin "codeberg-mcp" ''
    set -a
    . ${envFile}
    set +a
    exec ${python.interpreter} ${srcRepo}/server.py "$@"
  '';
in {
  sops.templates."codeberg-mcp.env" = {
    content = ''
      CODEBERG_ACCOUNTS={"default": "${config.sops.placeholder."codeberg-mcp/token"}"}
      MCP_TRANSPORT=stdio
    '';
    owner = "hermes";
    mode = "0400";
  };

  sops.secrets."codeberg-mcp/token" = {
    key = "codeberg_token";
    sopsFile = ../../secrets/codeberg.yml;
    owner = "hermes";
  };

  # Le binaire est disponible sur le PATH.
  environment.systemPackages = [codeberg-mcp-bin];

  services.hermes-agent.mcpServers.codeberg = {
    command = "${codeberg-mcp-bin}/bin/codeberg-mcp";
    timeout = 60;
  };
}
