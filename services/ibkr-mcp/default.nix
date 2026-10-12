# services/ibkr-mcp/default.nix
# Serveur MCP Interactive Brokers en LECTURE SEULE, adosse au Flex Web Service
# (HTTPS, sans session IBKR, sans 2FA, sans gateway local a faire tourner).
#
# Perimetre : positions, soldes, NAV, transactions, comptes. Les rapports sont
# generes a la demande (quelques secondes de latence), donc pas de cotation
# temps reel ni de carnet d'ordres. Pour du temps reel il faudrait un IB
# Gateway local (socket TWS 4001) pilote par IBC : hors perimetre ici, voir
# la note en bas de fichier.
#
# Actions humaines requises une fois (Client Portal, connexion obligatoire) :
#  1. Performance & Reports > Flex Queries > Flex Web Service Configuration :
#     cocher Flex Web Service Status, Save, puis Generate New Token (duree
#     jusqu'a 1 an ; laisser le champ IP vide, l'IP domestique change).
#  2. Performance & Reports > Flex Queries > creer une *Activity Flex Query*
#     avec au moins : Account Information, Open Positions, Cash Report,
#     Net Asset Value (NAV) in Base, Trades. Noter les identifiants (Query ID).
#  3. Poser token + identifiants dans secrets/ibkr.yml (voir le placeholder
#     ci-dessous), puis reactiver : tout ce qui n'est pas encore rempli reste
#     en erreur explicite cote tool `status`.
#
# Le token Flex est INDEPENDANT du mot de passe IBKR et revocable depuis le
# portail : le serveur ne detient aucun identifiant de compte, donc aucun
# pouvoir de passer un ordre.
{pkgs, config, ...}: let
  ibkr-mcp =
    pkgs.writers.writePython3Bin "ibkr-mcp" {
      libraries = [pkgs.python3Packages.mcp];
    } (builtins.readFile ./ibkr_flex.py);
in {
  # Dotenv genere depuis sops et relu a chaque appel par le serveur : ni le
  # token ni les identifiants de requetes ne sont dans le nix store (les `env`
  # du module sont world-readable dans la closure, donc jamais de secret ici).
  sops.templates."ibkr-flex.env" = {
    content = ''
      IBKR_FLEX_TOKEN=${config.sops.placeholder."ibkr/flex_token"}
      IBKR_FLEX_QUERY_ID=${config.sops.placeholder."ibkr/flex_query_id"}
      IBKR_FLEX_TRADES_QUERY_ID=${config.sops.placeholder."ibkr/flex_trades_query_id"}
    '';
    owner = "hermes";
    mode = "0400";
  };

  # TODO(marc) : remplacer les 3 valeurs de secrets/ibkr.yml (encore des
  # placeholders aujourd'hui) par le token et les Query ID reels, sinon le
  # serveur est deploye mais inerte : les tools existent et echouent en
  # "placeholder" a chaque appel. Verifier avec le tool `status`.
  sops.secrets."ibkr/flex_token" = {
    key = "flex_token";
    sopsFile = ../../secrets/ibkr.yml;
    owner = "hermes";
  };
  sops.secrets."ibkr/flex_query_id" = {
    key = "flex_query_id";
    sopsFile = ../../secrets/ibkr.yml;
    owner = "hermes";
  };
  sops.secrets."ibkr/flex_trades_query_id" = {
    key = "flex_trades_query_id";
    sopsFile = ../../secrets/ibkr.yml;
    owner = "hermes";
  };

  # Sur le PATH pour pouvoir sonder le serveur a la main (stdio).
  environment.systemPackages = [ibkr-mcp];

  services.hermes-agent.mcpServers.ibkr = {
    command = "${ibkr-mcp}/bin/ibkr-mcp";
    env.IBKR_FLEX_ENV_FILE = config.sops.templates."ibkr-flex.env".path;
    timeout = 120;
  };
}

# Phase 2 (non faite) : temps reel + carnet d'ordres. Exige IB Gateway (paquet
# absent de nixpkgs : telechargement IBKR a epingler), un X virtuel (xvfb),
# Java, un compte IBKR dont les identifiants vivent dans un fichier, et une
# validation 2FA sur telephone tous les dimanches apres 01:00 ET (IBKR
# l'impose au niveau du compte, IBC ne la contourne pas ; IBC est par ailleurs
# annonce deprecie depuis septembre 2026, remplacant = ibg-controller). A ne
# faire que si le besoin de cotation live est reel.
