# services/bank-mcp/default.nix
# Banking MCP (elcukro/bank-mcp) over stdio for Hermes: READ-ONLY access
# to Chase accounts via Teller (aggregator, free developer tier).
#
# 5 tools: list_accounts, list_transactions, search_transactions,
# get_balance, spending_summary. No write tool exists in the
# provider (the BankProvider interface only declares reads).
#
# Configuration: /var/lib/hermes/.bank-mcp/config.json (0600), written by
# `bank-mcp-setup` (interactive wizard) or `bank-mcp-connect` (new
# connection). It contains the Teller accessToken per connection, obtained via the
# Teller Connect widget, and the paths to the mTLS certificates.
#
# Setup (once):
#   1. teller.io -> create an application -> Application ID + teller.zip
#      (certificate.pem, private_key.pem) -> /var/lib/hermes/bank-mcp/certs/
#   2. `bank-mcp-setup`: Application ID, development environment,
#      paths to both .pem files, then the Teller Connect widget opens on
#      127.0.0.1 (Chase credentials entered there, never in the chat).
#
# Without config.json, the server still starts (tools/list responds) but
# every call fails with "No connections configured": a loud failure, not
# silent inertia.
{
  pkgs,
  lib,
  ...
}: let
  stateDir = "/var/lib/hermes/bank-mcp";
  certDir = "${stateDir}/certs";
  configDir = "/var/lib/hermes/.bank-mcp";

  bank-mcp = pkgs.buildNpmPackage {
    pname = "bank-mcp";
    version = "0.2.1";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@bank-mcp/server/-/server-0.2.1.tgz";
      hash = "sha256-2KDGKEk/s/asHq6PrJo/uMjqR3NkuhuK6lJDUq/cA9A=";
    };

    npmDepsHash = "sha256-38xLAj2VHW4/1e8L+UVayjzcL2xEjsqacywXFNigx9M=";

    # dist/ is already compiled in the published tarball.
    dontNpmBuild = true;

    # Published tarball without package-lock.json and with its devDependencies:
    # the lock committed here only covers the runtime, so we align the manifest.
    postPatch = ''
      cp ${./package-lock.json} package-lock.json
      ${lib.getExe pkgs.jq} 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';

    meta.mainProgram = "bank-mcp";
  };

  # The server reads its state from $HOME/.bank-mcp.
  withEnv = ''
    set -euo pipefail
    export HOME=/var/lib/hermes
  '';

  wrapper = pkgs.writeShellScript "bank-mcp-hermes" ''
    ${withEnv}
    exec ${lib.getExe bank-mcp}
  '';

  setup = pkgs.writeShellScriptBin "bank-mcp-setup" ''
    ${withEnv}
    exec ${lib.getExe bank-mcp} init
  '';

  connect = pkgs.writeShellScriptBin "bank-mcp-connect" ''
    ${withEnv}
    exec ${lib.getExe bank-mcp} connect
  '';
in {
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 hermes hermes -"
    "d ${certDir} 0700 hermes hermes -"
    "d ${configDir} 0700 hermes hermes -"
  ];

  environment.systemPackages = [setup connect];

  services.hermes-agent.mcpServers.bank = {
    command = "${wrapper}";
  };
}
