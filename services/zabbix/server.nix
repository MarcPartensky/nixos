# services/zabbix/server.nix : serveur Zabbix + frontal web, heberges sur le VPS.
#
# Pourquoi ici et pas sur tower : le serveur de supervision doit survivre a ce
# qu'il surveille. tower redemarre environ une fois par jour et son trafic
# sortant depend du tunnel newt ; le VPS tient un seul boot depuis des mois et
# c'est deja le plan de controle de tous les domaines. Frontal et base restent
# donc sur le VPS, les agents (services/zabbix/agent.nix) vont sur les machines.
#
# Empreinte : c'est la brique la plus lourde des trois (serveur C + frontal PHP
# + Postgres deja present), on l'assume sur le VPS (4 vCPU, charge < 1) et on ne
# la met jamais sur tower. Les agents, eux, sont negligeables (~15 Mo, < 0,1%).
#
# Base : Postgres locale au VPS, utilisateur et base `zabbix`, crees par
# ensureUsers/ensureDatabases. Auth : connexion par 127.0.0.1, ou la regle
# `host all all 127.0.0.1/32 trust` (services/postgres) s'applique en premier,
# donc AUCUN mot de passe a porter dans sops. C'est deja le regime des autres
# bases de tower (tout est en trust en local), et le port 5432 n'est joignable
# que depuis la loopback et le tailnet.
#
# Le frontal ecoute en LOOPBACK sur 9600 : 80/443 appartiennent a traefik
# (Pangolin), donc nginx ne doit surtout pas prendre le port. L'acces public
# passe par une ressource Pangolin `zabbix.marcpartensky.com` en cible locale du
# site rack (creee par l'API d'integration : le blueprint newt ne sert que les
# cibles d'un site newt, pas l'hote du plan de controle).
{ config, lib, ... }:
let
  port = 9600;
  domain = "zabbix.marcpartensky.com";
in
{
  services.postgresql = {
    ensureDatabases = [ "zabbix" ];
    ensureUsers = [
      {
        name = "zabbix";
        ensureDBOwnership = true;
      }
    ];
  };

  services.zabbixServer = {
    enable = true;

    database = {
      type = "pgsql";
      host = "127.0.0.1";
      name = "zabbix";
      user = "zabbix";
    };

    # Joignable depuis le tailnet par les agents (trappers). Le pare-feu du VPS
    # n'ouvre rien : tailscale0 est de confiance (services/tailscale).
    listen.ip = "0.0.0.0";
    listen.port = 10051;
    openFirewall = false;

    # Pas de `settings` pour l'instant : les valeurs par defaut sont dimensionnees
    # pour bien plus que six hotes, et une cle inconnue dans zabbix_server.conf
    # fait sortir le serveur au demarrage. On reglera les pollers apres la
    # premiere mesure de charge reelle.
  };

  services.zabbixWeb = {
    enable = true;
    frontend = "nginx";
    hostname = domain;

    server = {
      address = "127.0.0.1";
      port = 10051;
    };

    database = {
      type = "pgsql";
      host = "127.0.0.1";
      name = "zabbix";
      user = "zabbix";
    };

    nginx.virtualHost = {
      # Loopback uniquement, et surtout PAS le port 80 : traefik y sert tous les
      # domaines du VPS. forceSSL/addSSL restent a false, c'est traefik qui
      # termine le TLS.
      listen = [
        {
          addr = "127.0.0.1";
          port = port;
        }
      ];
      forceSSL = false;
      addSSL = false;
    };
  };

  # Ceinture et bretelles : si un vhost venait a ne pas declarer son `listen`, il
  # tomberait sur ce defaut au lieu du port 80.
  services.nginx.defaultListen = [
    {
      addr = "127.0.0.1";
      port = port;
    }
  ];

  # L'agent local : le VPS se surveille lui meme (disque, RAM, services), ce qui
  # couvre la panne qui a deja couche la pile entiere (disque plein le 10/11).
  services.zabbixAgent = {
    enable = true;
    server = "100.64.0.1";
    settings = {
      ServerActive = "100.64.0.1:10051";
      Hostname = config.networking.hostName;
    };
  };

  # Rappel volontaire : la base `zabbix` vit sur le VPS, dont AUCUNE base n'est
  # sauvegardee aujourd'hui (pqbox dumpe les bases de tower). A ajouter a la
  # chaine de sauvegarde, comme le coffre si celui ci revient ici.
  warnings = [
    "Zabbix : la base sur le VPS n'est pas couverte par pqbox (cf. services/backup-pqbox)."
  ];
}
