# services/zabbix/agent.nix : agent Zabbix des machines surveillees.
#
# Le serveur vit sur le VPS (services/zabbix/server.nix, importe uniquement par
# profiles/anywhere). Les agents le joignent par le TAILNET (100.64.0.1), pas
# par l'exterieur : `networking.firewall.trustedInterfaces = [ "tailscale0" ]`
# (services/tailscale) suffit, aucun port a ouvrir, et le trafic est deja
# chiffre par WireGuard.
{ config, ... }:
let
  # anywhere (le VPS), adresse tailnet. Le serveur ecoute sur 0.0.0.0:10051.
  server = "100.64.0.1";
in
{
  services.zabbixAgent = {
    enable = true;

    # Checks passifs : c'est le serveur qui interroge l'agent, en revenant par le
    # tailnet. L'option `server` du module alimente la ligne `Server` du fichier
    # de conf, elle accepte une liste separee par des virgules.
    server = server;

    settings = {
      # Checks actifs : l'agent pousse vers le serveur.
      ServerActive = "${server}:10051";
      # Nom de l'hote cote serveur. C'est ce nom qui doit exister dans Zabbix
      # (les hotes sont crees par l'API : Zabbix garde son inventaire dans sa
      # base, pas dans le nix).
      Hostname = config.networking.hostName;
    };
  };
}
