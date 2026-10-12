# services/gitea-mcp/default.nix
# Serveur MCP Gitea officiel (gitea.com/gitea/gitea-mcp) pour hermes.
# Transport stdio : hermes spawn le subprocess (mcpServers dans
# services/hermes/default.nix, command = "gitea-mcp").
#
# Version v1.6.0 et pas la dernière (v1.7.0) : v1.7.0 exige go >= 1.27 alors que
# la nixpkgs épinglée (26.05) fournit go 1.26.7 -> échec du build des modules.
# v1.6.0 exige go 1.26.0, donc compatible, ET supporte GITEA_ACCESS_TOKEN_FILE
# (le secret sops est lu par le binaire, jamais passé en clair dans l'env).
#
# Auth : Personal Access Token Gitea (Settings -> Applications -> Generate Token,
# scopes: repo, admin:org, admin:user, notification, user, write:package, read:package).
# Le token vit dans secrets/gitea-mcp.yml (sops, clé gitea_mcp_pat).
{
  config,
  lib,
  pkgs,
  ...
}: let
  version = "1.6.0";
  gitea-mcp = pkgs.buildGoModule {
    pname = "gitea-mcp";
    inherit version;
    src = pkgs.fetchzip {
      url = "https://gitea.com/gitea/gitea-mcp/archive/v${version}.tar.gz";
      hash = "sha256-A4HqHEicIdq7L/hmQ+tWeTJWnVscSIfCn3ku1dKSCkY=";
    };
    vendorHash = "sha256-BYHcV5WSklGqdeTN7S2AMtscJDCA/8n1gEOgLzr9Gmk=";
    subPackages = ["."];
    ldflags = ["-s" "-w"];
    meta = with pkgs.lib; {
      description = "Gitea Model Context Protocol server";
      homepage = "https://gitea.com/gitea/gitea-mcp";
      license = licenses.mit;
      mainProgram = "gitea-mcp";
    };
  };
in {
  # Le binaire sur le PATH (c'est ce que référence mcpServers.gitea.command)
  environment.systemPackages = [gitea-mcp];

  # Secret PAT Gitea (créé dans Gitea -> Settings -> Applications)
  sops.secrets."gitea-mcp/pat" = {
    key = "gitea_mcp_pat";
    sopsFile = ../../secrets/gitea-mcp.yml;
    owner = "hermes";
    mode = "0400";
  };
}
