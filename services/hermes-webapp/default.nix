# services/hermes-webapp/default.nix
# Webapp Hermes : le front de l'app DESKTOP servi dans un navigateur.
#
# Ce n'est pas le dashboard (services/hermes-dashboard, dash.marcpartensky.com)
# ni le WebUI tiers (services/hermes-webui) : c'est le renderer React du desktop,
# servi par le GATEWAY du profil default sur son propre listener
# (`gateway/webapp_listener.py`, `webapp:` dans config.yaml). Une seule
# conversation, partagée avec le CLI, le desktop natif et Matrix, puisque c'est
# le même process gateway qui sert tout le monde.
#
# Chaîne : Pangolin (hermes.marcpartensky.com, ressource `hermes-webui` du
#          blueprint newt, cible retargetée vers ce proxy)
#          -> 127.0.0.1:9124 (nginx)
#          -> 127.0.0.1:9123 (listener Webapp du gateway, profil default)
#
# Pourquoi nginx ne réécrit PAS Host ici (contrairement à hermes-dashboard) :
# `webapp.public_url` déclare l'hôte public comme hôte de confiance du listener
# (`web_server_boundary._is_accepted_host`), donc le garde anti-DNS-rebinding et
# la validation d'Origin des WebSockets (`/api/ws`) acceptent le vrai Host. Le
# réécrire en 127.0.0.1:9123 ferait rejeter l'Origin par le garde WS.
#
# Auth : `public_url` ENGAGE la porte de connexion du dashboard même sur un bind
# loopback (`listener_auth_required` + `public_hosts_engage_gate`). Le provider
# est le mot de passe simple (plugins/dashboard_auth/basic), alimenté par le
# fichier sops `hermes_webapp_gate_env` (identifiant, mot de passe, clé de
# signature des sessions). Aucune valeur secrète n'entre dans le store nix.
#
# Isolation : la Webapp sert UN profil, donc UN agent. Toute personne qui passe
# la porte voit TOUTES les sessions de ce profil (pas de cloisonnement par
# compte). D'où un gate mono-utilisateur tant qu'il n'y a qu'un profil ; un
# utilisateur par personne = un profil + un gateway standalone par personne.
{
  config,
  lib,
  ...
}: let
  webappPort = 9123;
  proxyPort = 9124;
  webappHost = "127.0.0.1:${toString webappPort}";
  publicUrl = "https://hermes.marcpartensky.com";
in {
  # Le gateway relit `webapp` à son démarrage : un switch ne fait que poser la
  # config (restartIfChanged = false côté unité), le listener apparaît au
  # prochain redémarrage du gateway.
  services.hermes-agent.settings.webapp = {
    enabled = true;
    host = "127.0.0.1";
    port = webappPort;
    public_url = publicUrl;
  };

  # Gate : identifiant + mot de passe (hashé en mémoire au démarrage) + clé de
  # signature. Contenu dotenv, concaténé dans $HERMES_HOME/.env à l'activation.
  sops.secrets."hermes_webapp_gate_env" = lib.mkIf config.services.hermes.enableAgent {
    key = "hermes_webapp_gate_env";
    sopsFile = ../../secrets/hermes-webapp.yml;
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode = "0400";
  };

  services.hermes-agent.environmentFiles = lib.mkIf config.services.hermes.enableAgent [
    config.sops.secrets."hermes_webapp_gate_env".path
  ];

  services.nginx.virtualHosts."hermes-webapp-proxy" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    locations."/" = {
      proxyPass = "http://${webappHost}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
      '';
    };
  };

  # Garde-fou : jamais de port au firewall (la Webapp donne un shell complet).
  assertions = [
    {
      assertion = !(lib.elem webappPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webapp : le port ${toString webappPort} (front desktop, outils et terminal) ne doit pas être ouvert au firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webapp : le port ${toString proxyPort} (proxy du listener Webapp) ne doit pas être ouvert au firewall.";
    }
  ];
}
