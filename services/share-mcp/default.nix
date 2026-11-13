# services/share-mcp/default.nix
# MCP `share` (code dans ./server.py) : publie un fichier dans le bucket public
# de Garage, crée le lien court Shlink dessus, et optionnellement une façade
# x.gd de 4 caractères. Un seul appel fait les trois jambes.
#
# Répartition avec services/garage : Garage porte la capacité (section `web` de
# garage.toml, bucket `public` marqué website, placeholder de santé). Ce module
# porte la face PUBLIQUE de cette capacité : la ressource Pangolin
# files.marcpartensky.com et l'outillage qui la consomme.
#
# SSO volontairement DÉSACTIVÉ sur files.marcpartensky.com : le domaine sert de
# cible aux liens courts, donc un 302 vers Zitadel casserait tous les liens
# partagés. Contrepartie assumée : tout objet du bucket `public` est lisible par
# qui connaît son URL. Les buckets artifacts et photos-* ne sont pas marqués
# website, donc Garage continue de les refuser en anonyme sur ce même endpoint.
{self, pkgs, config, ...}: let
  # Port de l'endpoint web Garage (déclaré dans services/garage).
  webPort = 3902;

  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf, et plus reconstruit a chaque eval de l'hote.
  share-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.share-mcp;

  # Wrapper : les identifiants S3 sont générés à l'activation par
  # garage-bootstrap et vivent dans /var/lib/garage/s3-key.env (0400 hermes),
  # jamais dans le store. Le binaire `aws` vient d'ici, pas de la config.
  # Debug à la main (garder stdin ouvert, un EOF tue la requête) :
  #   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
  #     | /nix/store/.../bin/share-mcp-hermes
  wrapper = pkgs.writeShellScript "share-mcp-hermes" ''
    set -euo pipefail
    # shellcheck disable=SC1091
    . /var/lib/garage/s3-key.env
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    export PATH=${pkgs.awscli2}/bin:$PATH
    exec ${share-mcp}/bin/share-mcp
  '';
in {
  environment.systemPackages = [share-mcp];

  services.hermes-agent.mcpServers.share = {
    command = "${wrapper}";
    args = [];
    env = {
      SHARE_BUCKET = "public";
      # Domaine public servant le bucket (path-style /<bucket>/<cle>).
      SHARE_PUBLIC_BASE = "https://files.marcpartensky.com/public";
      SHARE_S3_ENDPOINT = "http://127.0.0.1:3900";
      SHARE_ALLOW_WRITES = "1";
      SHLINK_URL = "http://127.0.0.1:8097";
      SHLINK_API_KEY_FILE = config.sops.secrets.shlink_api_key.path;
    };
    # Les dépôts de fichiers dépassent les 60 s des autres serveurs MCP.
    timeout = 900;
  };

  # Ressource publique Pangolin : files.marcpartensky.com -> endpoint web
  # Garage. Schéma `proxy-resources` + `protocol` (celui qui marche sur ce
  # contrôleur). Healthcheck sur le placeholder déposé par le bootstrap :
  # Garage répond 404 sur la racine d'un bucket sans index.html.
  services.newt.blueprint.proxy-resources.files = {
    name = "files";
    protocol = "http";
    full-domain = "files.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = webPort;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = webPort;
          path = "/public/_health.txt";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # Garde-fou : l'endpoint web ne doit jamais être ouvert au LAN, il n'est
  # joignable que par la loopback (MCP, tests) et par newt (Pangolin).
  assertions = [
    {
      assertion = !(builtins.elem webPort
        config.networking.firewall.allowedTCPPorts);
      message = "share-mcp : le port ${toString webPort} de Garage ne doit pas être ouvert au firewall.";
    }
  ];
}
