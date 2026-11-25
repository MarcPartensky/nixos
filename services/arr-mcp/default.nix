# services/arr-mcp/default.nix
# Serveur MCP arr-mcp (bardesss/arr-mcp) : UN endpoint pour la pile media
# auto-hebergee (Radarr films, Sonarr series, Prowlarr indexeurs, Jellyfin).
# Conteneur sorti de la conf hote : deploy/containers.nix (entree `arr-mcp`,
# migrated = true), quadlet podman `arr-mcp.service`, publie sur
# 127.0.0.1:6060.
#
# Ce que nix possede :
#   - le conteneur : image, port, volume /config, fichier d'env ;
#   - les cles API des quatre services et le token MCP, dans
#     secrets/arr-mcp.yml (destinataire = tower uniquement) ;
#   - l'entree MCP de Hermes, dont le header porte un placeholder
#     ${ARR_MCP_TOKEN} : Hermes le resout depuis son environnement au moment
#     de se connecter, donc aucun secret n'entre dans config.yaml ni ici.
#
# Ce que nix ne possede PAS : /var/lib/hermes/arr-mcp/config.yaml, la config
# applicative que le dashboard du conteneur reecrit (URL des services, hash du
# token, default_user Jellyfin). Elle ne porte aucun secret : les cles API y
# sont des placeholders ${RADARR_API_KEY} et compagnie que le conteneur resout
# depuis /run/secrets/arr_mcp_env, et le token n'y figure que hache (sha256).
{ config, ... }: let
  port = 6060;
in {
  # Un fichier sops, deux secrets, parce que les deux consommateurs n'ont pas
  # besoin de la meme chose : le conteneur veut les quatre cles API, hermes
  # seulement le token MCP (aucune raison de lui donner les cles des *arr).
  sops.secrets."arr_mcp_env" = {
    sopsFile = ../../secrets/arr-mcp.yml;
    owner = "hermes";
  };
  sops.secrets."hermes_arr_mcp_env" = {
    sopsFile = ../../secrets/arr-mcp.yml;
    owner = "hermes";
  };

  # environmentFiles est concatene dans $HERMES_HOME/.env : c'est de la que
  # Hermes lit ${ARR_MCP_TOKEN} pour le header ci-dessous.
  services.hermes-agent.environmentFiles = [
    config.sops.secrets."hermes_arr_mcp_env".path
  ];

  # L'URL passe par le redirecteur LAN de services/mcp-lan-access pour etre
  # cliquable depuis Hermes Desktop sur le Mac ; cote tower, le trafic local
  # repasse par lo.
  services.hermes-agent.mcpServers.arrmcp = {
    url =
      if config.services.mcp-lan-access.enable
      then "http://${config.services.mcp-lan-access.host}:${toString port}/mcp"
      else "http://127.0.0.1:${toString port}/mcp";
    # \${...} : le placeholder doit arriver LITTERALEMENT dans config.yaml,
    # c'est Hermes qui le resout a la connexion (doc MCP : ${VAR} dans url et
    # headers, lu depuis l'environnement du process).
    headers.Authorization = "Bearer \${ARR_MCP_TOKEN}";
    timeout = 120;
  };
}
