# services/bank-mcp/default.nix
# MCP bancaire (elcukro/bank-mcp) en stdio pour Hermes : accès LECTURE SEULE
# aux comptes Chase via Teller (agrégateur, tier développeur gratuit).
#
# 5 tools : list_accounts, list_transactions, search_transactions,
# get_balance, spending_summary. Aucun tool d'écriture n'existe dans le
# provider (l'interface BankProvider ne déclare que des lectures).
#
# Configuration : /var/lib/hermes/.bank-mcp/config.json (0600), écrite par
# `bank-mcp-setup` (assistant interactif) ou `bank-mcp-connect` (nouvelle
# connexion). Elle contient l'accessToken Teller par connexion, obtenu via le
# widget Teller Connect, et les chemins des certificats mTLS.
#
# Mise en route (une fois) :
#   1. teller.io -> créer une application -> Application ID + teller.zip
#      (certificate.pem, private_key.pem) -> /var/lib/hermes/bank-mcp/certs/
#   2. `bank-mcp-setup` : Application ID, environnement development,
#      chemins des deux .pem, puis le widget Teller Connect s'ouvre sur
#      127.0.0.1 (identifiants Chase à saisir là, jamais dans le chat).
#
# Sans config.json, le serveur démarre quand même (tools/list répond) mais
# chaque appel échoue en « No connections configured » : échec bruyant, pas
# d'inertie silencieuse.
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

    # dist/ est déjà compilé dans le tarball publié.
    dontNpmBuild = true;

    # Tarball publié sans package-lock.json et avec ses devDependencies :
    # la lock committée ici ne couvre que le runtime, on aligne le manifeste.
    postPatch = ''
      cp ${./package-lock.json} package-lock.json
      ${lib.getExe pkgs.jq} 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';

    meta.mainProgram = "bank-mcp";
  };

  # Le serveur lit son état dans $HOME/.bank-mcp.
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
