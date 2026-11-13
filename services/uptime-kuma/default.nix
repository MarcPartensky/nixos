# services/uptime-kuma : moniteur de disponibilite bout en bout.
#
# Remplit le trou que Zabbix ne voit pas de la meme facon : il sonde les
# domaines PUBLICS depuis l'exterieur (HTTP, TCP), donc il attrape une panne
# d'exposition (tunnel newt tombe, ressource Pangolin en 502, certificat expire)
# meme quand toutes les machines vont bien. C'est exactement la panne qui est
# restee invisible 26 h le 10/11.
#
# Heberge sur le VPS, comme Zabbix : un moniteur qui vit sur la machine qu'il
# surveille ne peut rien annoncer de sa panne. A savoir : Gotify et Matrix
# tournent sur TOWER, donc leurs alertes sont muettes quand tower tombe ; pour
# ce cas la, la sonde inverse est cote tower et l'alerte doit partir du VPS
# (mail via stalwart, qui vit ici).
#
# Empreinte : Node, de l'ordre de 0,5 a 1% de CPU et 150 a 250 Mo. L'UI et les
# sondes vivent dans SQLite (/var/lib/uptime-kuma) : ce n'est pas Postgres, mais
# c'est un fichier unique, trivial a sauvegarder (et la demande Postgres en
# amont est encore ouverte).
#
# Le service tourne en DynamicUser avec un sandbox systemd strict et
# AmbientCapabilities = "" : les sondes ICMP (ping) ne peuvent donc pas ouvrir
# de socket brut. On surveille les machines par TCP (port 22 sur le tailnet),
# ce qui est aussi informatif, et les domaines par HTTP.
#
# Acces : ressource Pangolin `uptime.marcpartensky.com` vers 127.0.0.1:3001, en
# cible locale du site rack, SANS SSO : le client Android (OpenKuma) et l'API ne
# suivent pas une redirection de login. Uptime Kuma a son propre compte et son
# 2FA pour compenser.
{ ... }:
{
  services.uptime-kuma = {
    enable = true;

    settings = {
      # Loopback : c'est traefik (Pangolin) qui expose, pas le pare-feu.
      HOST = "127.0.0.1";
      PORT = "3001";
      DATA_DIR = "/var/lib/uptime-kuma/";
      UPTIME_KUMA_DB_TYPE = "sqlite";
    };
  };
}
