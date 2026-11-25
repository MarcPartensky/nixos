# services/wise-mcp/default.nix
# Wise MCP server (BlanketByte/wise-mcp) launched over stdio by Hermes on tower.
#
# READ-ONLY: WRITES_ENABLED=false removes the write tools (quotes,
# recipients, transfers, cancellations). 7 read tools remain:
# list_profiles, list_balances, get_transactions (activity + card payments),
# list_transfers, get_transfer, list_recipients, get_exchange_rate.
#
# The server validates the token AT STARTUP by calling Wise: a missing,
# expired or revoked token makes the process die with "Wise rejected
# WISE_API_TOKEN", so the server cannot stay silently inert.
#
# Token : wise.com -> Settings -> API tokens -> Add new token (Read only),
# then secrets/wise.yml (key wise_api_token, encrypted to tower's age key).
#
# Known limitation of the Wise API with a personal token (EU/UK accounts, PSD2):
# no account statement (running balance per transaction) and no list of
# cards. The activity feed, however, does contain the card payments.
{
  config,
  pkgs,
  lib,
  ...
}: let
  stateDir = "/var/lib/hermes/wise-mcp";

  wise-mcp = pkgs.buildNpmPackage {
    pname = "wise-mcp";
    version = "1.1.1";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@blanketbyte/wise-mcp/-/wise-mcp-1.1.1.tgz";
      hash = "sha256-FyaW14LLIc7MQvunDnMtd0EVhF3uF9gIMeYbR/lgbpI=";
    };

    npmDepsHash = "sha256-M6ubVdsYic4NB8OBptwsS+8eaPkdX/Ev9VhjDmvCnIM=";

    # The published tarball ships a precompiled dist/.
    dontNpmBuild = true;

    # The published tarball does not include a package-lock.json and keeps its
    # devDependencies; the lock committed alongside only covers the runtime
    # (nothing is compiled here), so we drop the devDeps from the manifest.
    postPatch = ''
      cp ${./package-lock.json} package-lock.json
      ${lib.getExe pkgs.jq} 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';

    meta.mainProgram = "wise-mcp";
  };

  wrapper = pkgs.writeShellScript "wise-mcp-hermes" ''
    set -euo pipefail
    export WISE_API_TOKEN="$(cat ${config.sops.secrets.wise_api_token.path})"
    export WRITES_ENABLED=false
    export DATA_DIR=${stateDir}
    exec ${lib.getExe wise-mcp}
  '';
in {
  sops.secrets.wise_api_token = {
    sopsFile = ../../secrets/wise.yml;
    owner = "hermes";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 hermes hermes -"
  ];

  services.hermes-agent.mcpServers.wise = {
    command = "${wrapper}";
  };
}
