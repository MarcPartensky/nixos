# Glances en mode web : un « htop web » pour examiner les taches de tower.
#
# Le module nixpkgs (services.glances) lance `glances --webserver` en
# DynamicUser avec un sandbox systemd durci. L'UI (table de processus triable,
# graphes CPU/RAM/reseau, API REST) ecoute sur 0.0.0.0:61208. Le firewall
# reste FERME (openFirewall = false par defaut) : l'acces distant passe
# uniquement par la ressource Pangolin `proc.marcpartensky.com` (newt tape la
# loopback, SSO active cote Pangolin), comme kasm/vnc.
#
# Chemins de sante pour newt : `/` et `/api/4/status` repondent 200.
{ ... }:
{
  services.glances.enable = true;

  # extraArgs par defaut : [ "--webserver" ]. Le rafraichissement par defaut
  # (1 s) suffit pour l'oeil humain ; passer par services.glances.extraArgs
  # pour ajouter -t (intervalle) ou -B (bind) le jour ou besoin.
}
