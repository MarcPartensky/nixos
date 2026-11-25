# services/enable-banking-mcp/default.nix
# Serveur MCP Enable Banking (PSD2 AIS, lecture seule) pour hermes :
# comptes, soldes et transactions de banques europeennes (Caisse
# d'Epargne via BPCE, SCA Banxo), transport stdio. 8 tools : status,
# list_institutions, connection_create, session_create/get/delete,
# account_details/balances/transactions.
#
# Credential : JSON {"app_id", "private_key"} de l'app enregistree au
# panneau https://enablebanking.com/cp (environnement PRODUCTION, mode
# restricted par linked accounts = gratuit pour usage personnel). La
# clee privee a ete generee ici (openssl 4096) ; le certificat public a
# telecharger est celui upload lors de l'inscription de l'app. Relu a
# chaque appel via ENABLE_BANKING_APP_FILE : aucune rotation ne demande
# un redemarrage de hermes.
#
# TODO(marc): app_id encore PLACEHOLDER — le serveur est deploye mais
# INERTE (status le dit explicitement) tant que l'app n'est pas
# enregistree au panneau. Quand l'app_id arrive, RECREER le fichier
# sops (supprimer + re-encrypter depuis les cles publiques, aucune cle
# privee requise) :
#   cd /home/marc/git/nixos
#   python3 - <<'PY'
#   import json
#   key = open("/var/lib/hermes/.hermes/cache/scratch/eb/private.key").read()
#   print("app: " + json.dumps({"app_id": "<APP_ID>", "private_key": key}))
#   PY > /tmp/eb-plain.yml
#   nix run nixpkgs#sops -- -e --filename-override secrets/enable-banking.yml \
#     --output secrets/enable-banking.yml /tmp/eb-plain.yml
#   shred -u /tmp/eb-plain.yml
#
# Contraintes : JWT RS256 a signer par appel (fait dans le serveur, TTL
# 1 h) ; consentement ~90-180 jours puis re-link ; seule l'app restreinte
# lit les comptes qu'elle a lies.
{
  pkgs,
  config,
  ...
}:
let
  enable-banking-mcp = pkgs.writers.writePython3Bin "enable-banking-mcp"
    {
      libraries = [
        pkgs.python3Packages.mcp
        pkgs.python3Packages.cryptography
      ];
    } (builtins.readFile ./enable_banking_mcp.py);
in
{
  services.hermes-agent.mcpServers.enable-banking = {
    command = "${enable-banking-mcp}/bin/enable-banking-mcp";
    env.ENABLE_BANKING_APP_FILE =
      config.sops.secrets.enable_banking_app.path;
    timeout = 120;
  };

  sops.secrets.enable_banking_app = {
    sopsFile = ../../secrets/enable-banking.yml;
    key = "app";
    owner = "hermes";
    mode = "0400";
  };

  # Sur le PATH pour sonder le serveur a la main (stdio).
  environment.systemPackages = [ enable-banking-mcp ];
}
