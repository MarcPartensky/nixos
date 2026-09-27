# services/hermes-pocket/default.nix
# Backend de l'appli mobile Hermes Pocket : `hermes serve --isolated` sur le
# profil « pocket », instance séparée du gateway Matrix (hermes-agent) et du
# dashboard web (hermes-dashboard).
#
# Chaîne : Pangolin (hermes-mobile.marcpartensky.com, SSO DÉSACTIVÉ)
#          -> newt (site tower)
#          -> 127.0.0.1:9129 (nginx, réécrit Host: 127.0.0.1:9119)
#          -> 127.0.0.1:9119 (hermes serve --isolated, profil pocket).
#
# L'appli ouvre ws(s)://<domaine>/api/ws?token=<HERMES_DASHBOARD_SESSION_TOKEN>.
# Deux points vérifiés le 27/09/2026 sur cette machine :
#  1. Le serveur n'accepte le token QU'en paramètre de requête (Authorization:
#     Bearer est refusé en 403), d'où la ressource Pangolin sans SSO : l'appli
#     native ne peut pas faire le flux navigateur. La protection est donc le
#     token de session du profil pocket (profiles/pocket/serve.env, 0600).
#  2. Le serveur refuse tout en-tête Host non loopback (anti DNS-rebinding),
#     d'où la réécriture Host par nginx, comme dans hermes-webui et
#     hermes-dashboard.
# Ne jamais ouvrir 9119 ou 9129 au firewall : le serveur expose l'API complète
# de l'agent (outils, fichiers, terminal) et le token protège tout l'accès.
{
  config,
  lib,
  ...
}: let
  profileDir = "/var/lib/hermes/.hermes/profiles/pocket";
  backendPort = 9119;
  proxyPort = 9129;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  systemd.services.hermes-pocket-serve = {
    description = "Hermes serve (profil pocket) : backend de l'appli mobile Hermes Pocket";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = config.services.hermes-agent.user;
      Group = config.services.hermes-agent.group;

      # même cwd que la session d'origine de l'appli (cf. README du projet)
      WorkingDirectory = "/var/lib/hermes/workspace";

      # HERMES_HOME pointe sur le profil, et --isolated empêche le rattachement
      # au serveur unifié de la machine (qui est celui du dashboard).
      Environment = [
        "HERMES_HOME=${profileDir}"
        "HERMES_REAL_HOME=/var/lib/hermes"
      ];

      # .env = clés de provider du profil ; serve.env = token de session
      # (HERMES_DASHBOARD_SESSION_TOKEN), les deux hors du store nix.
      EnvironmentFile = [
        "${profileDir}/.env"
        "${profileDir}/serve.env"
      ];

      ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --isolated --port ${toString backendPort} --host 127.0.0.1";

      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Proxy local : seul point d'entrée loopback, il réécrit le Host que le
  # serveur impose, et laisse passer l'Upgrade WebSocket.
  services.nginx.virtualHosts."hermes-pocket-proxy" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    locations."/" = {
      proxyPass = backendUrl;
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host ${backendHost};
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
      '';
    };
  };

  # Ressource publique Pangolin, appliquée par le site qui porte le blueprint
  # (donc tower) : `site` est omis volontairement, cf. services/newt.
  # Pas de bloc `auth` : c'est le seul moyen de laisser l'appli native se
  # connecter (SSO navigateur impossible), exactement comme la ressource
  # jellyfin. La cible reste loopback, seul nginx est publié.
  services.newt.blueprint.proxy-resources.hermes-pocket = {
    name = "Hermes Pocket (appli mobile)";
    protocol = "http";
    full-domain = "hermes-mobile.marcpartensky.com";
    targets = [
      {
        hostname = "127.0.0.1";
        port = proxyPort;
        method = "http";
      }
    ];
  };

  # Garde-fou : ces ports ne doivent jamais être ouverts sur le LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-pocket : le port ${toString backendPort} (API agent complète, protégée par un simple token) ne doit pas être ouvert au firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-pocket : le port ${toString proxyPort} (proxy du backend) ne doit pas être ouvert au firewall.";
    }
  ];
}
