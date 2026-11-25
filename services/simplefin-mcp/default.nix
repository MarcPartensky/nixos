# services/simplefin-mcp/default.nix
# Serveur MCP SimpleFIN (lecture seule) pour hermes : comptes et transactions
# Chase via le SimpleFIN Bridge, transport stdio. 5 tools : status,
# list_accounts, get_transactions, search_transactions, spending_summary.
#
# Credential : l'access URL du Bridge (identifiants Basic embarqués), dans
# secrets/simplefin.yml (clé simplefin_access_url). Elle s'obtient en
# réclamant un Setup Token (usage unique) :
#   python3 /var/lib/hermes/.hermes/scripts/simplefin_claim.py <token>
# puis en réencryptant ce fichier sops depuis le clair (clé publique tower
# seule, aucune clé privée requise) :
#   cd /home/marc/git/nixos
#   printf 'simplefin_access_url: "%s"\n' \
#     "$(cat /var/lib/hermes/.hermes/simplefin-access-url)" > /tmp/plain.yml
#   sops -e --filename-override secrets/simplefin.yml /tmp/plain.yml \
#     > secrets/simplefin.yml
#   shred -u /tmp/plain.yml
#
# Limites du Bridge : 24 requêtes/jour, fenêtre 90 jours max, lecture seule,
# abonnement 15 USD/an à régler sinon /accounts répond 402 « Payment
# required » (le tool status le dit explicitement).
#
# Le serveur relit le fichier secret À CHAQUE appel (rien en env de closure
# ni dans le store) : une rotation de l'access URL ne demande aucun
# redémarrage de hermes.
{pkgs, config, ...}: let
  simplefin-mcp =
    pkgs.writers.writePython3Bin "simplefin-mcp" {
      libraries = [pkgs.python3Packages.mcp];
      flakeIgnore = ["E501" "W503" "W504"];
    } (builtins.readFile ./simplefin_mcp.py);
in {
  sops.secrets.simplefin_access_url = {
    sopsFile = ../../secrets/simplefin.yml;
    owner = "hermes";
    mode = "0400";
  };

  # Sur le PATH pour sonder le serveur à la main (stdio).
  environment.systemPackages = [simplefin-mcp];

  services.hermes-agent.mcpServers.simplefin = {
    command = "${simplefin-mcp}/bin/simplefin-mcp";
    env.SIMPLEFIN_ACCESS_URL_FILE = config.sops.secrets.simplefin_access_url.path;
    timeout = 120;
  };
}
