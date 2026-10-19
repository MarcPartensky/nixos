# services/wise-mcp/default.nix
# Serveur MCP Wise (BlanketByte/wise-mcp) lancé en stdio par Hermes sur tower.
#
# LECTURE SEULE : WRITES_ENABLED=false retire les tools d'écriture (devis,
# bénéficiaires, virements, annulations). Il reste 7 tools de lecture :
# list_profiles, list_balances, get_transactions (activité + paiements carte),
# list_transfers, get_transfer, list_recipients, get_exchange_rate.
#
# Le serveur valide le token AU DÉMARRAGE en appelant Wise : un token absent,
# expiré ou révoqué fait mourir le process avec « Wise rejected
# WISE_API_TOKEN », donc le serveur ne peut pas rester inerte en silence.
#
# Token : wise.com -> Settings -> API tokens -> Add new token (Read only),
# puis secrets/wise.yml (clé wise_api_token, chiffré vers la clé age de tower).
#
# Limite connue de l'API Wise avec un token personnel (comptes EU/UK, PSD2) :
# pas de relevé de compte (solde courant par transaction) ni de liste des
# cartes. Le flux d'activité, lui, contient bien les paiements par carte.
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

    # Le tarball publie un dist/ déjà compilé.
    dontNpmBuild = true;

    # Le tarball publié n'embarque pas de package-lock.json et garde ses
    # devDependencies ; la lock committée à côté ne couvre que le runtime
    # (rien n'est compilé ici), donc on retire les devDeps du manifeste.
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
