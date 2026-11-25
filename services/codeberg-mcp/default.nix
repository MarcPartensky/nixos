# services/codeberg-mcp/default.nix
# Codeberg MCP server (effecet/codeberg-mcp): 49 tools.
# The package is created here; the mcpServers is configured in
# services/hermes/default.nix (or here, the option is the same).
#
# The Codeberg token is NEVER in clear text in the nix store: it lives in
# secrets/codeberg.yml (sops), is injected into a generated .env (sops.templates),
# and the wrapper "sources" it before exec-ing the server.
# Create the token: https://codeberg.org/user/settings/applications
# (scopes read/write:repository, read/write:issue, read:user).
{
  pkgs,
  lib,
  config,
  ...
}: let
  # Runtime deps from the repo's requirements.txt (mcp SDK, httpx,
  # python-dotenv, uvicorn). Without them server.py dies at import time
  # ("No module named 'dotenv'") and the MCP host has to exclude it.
  python = pkgs.python312.withPackages (ps: [
    ps.mcp
    ps.httpx
    ps.python-dotenv
    ps.uvicorn
  ]);
  srcRepo = pkgs.fetchFromGitHub {
    owner = "effecet";
    repo = "codeberg-mcp";
    rev = "f7e2fa06ca097cfa5638cef3768c35072c554fd9";
    # base32 nix-prefetch-url hash -> SRI: since Nix 2.x a bare hash no longer has
    # a type and makes the WHOLE evaluation of the tower config fail.
    hash = "sha256-ElfVEkftD02XHQ6Cu6viaIRvSuw+kFvvmGzvzUPnnb4=";
  };

  # .env generated from sops (contains CODEBERG_ACCOUNTS with the real token),
  # readable by hermes only.
  envFile = config.sops.templates."codeberg-mcp.env".path;

  # Manual Python package: the repo has no valid build-system.
  # The wrapper "sources" the sops .env then runs server.py.
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

  # The binary is available on the PATH.
  environment.systemPackages = [codeberg-mcp-bin];

  services.hermes-agent.mcpServers.codeberg = {
    command = "${codeberg-mcp-bin}/bin/codeberg-mcp";
    timeout = 60;
  };
}
