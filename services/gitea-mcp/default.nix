# services/gitea-mcp/default.nix
# Official Gitea MCP server (gitea.com/gitea/gitea-mcp) for hermes.
# stdio transport: hermes spawns the subprocess (mcpServers in
# services/hermes/default.nix, command = "gitea-mcp").
#
# Version v1.6.0, not the latest (v1.7.0): v1.7.0 requires go >= 1.27 while
# the pinned nixpkgs (26.05) provides go 1.26.7 -> module build fails.
# v1.6.0 requires go 1.26.0, so it is compatible, AND supports GITEA_ACCESS_TOKEN_FILE
# (the sops secret is read by the binary, never passed in cleartext in the env).
#
# Auth: Gitea Personal Access Token (Settings -> Applications -> Generate Token,
# scopes: repo, admin:org, admin:user, notification, user, write:package, read:package).
# The token lives in secrets/gitea-mcp.yml (sops, key gitea_mcp_pat).
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
  # The binary on PATH (this is what mcpServers.gitea.command references)
  environment.systemPackages = [gitea-mcp];

  # Gitea PAT secret (created in Gitea -> Settings -> Applications)
  sops.secrets."gitea-mcp/pat" = {
    key = "gitea_mcp_pat";
    sopsFile = ../../secrets/gitea-mcp.yml;
    owner = "hermes";
    mode = "0400";
  };
}
