# services/hermes-dashboard/default.nix
# Terminal web + panneau d'admin de Hermes sur tower.
#
# Rien à packager : le backend est déjà dans l'input `hermes-agent` du flake.
# `hermes serve` et `hermes dashboard` sont le MÊME point d'entrée, à un flag
# près, et les deux exposent les sockets /api/ws et /api/pty. C'est /api/pty
# qui est le terminal web ; `dashboard` ajoute en plus l'interface navigateur
# sur le même port. Un seul des deux modes peut tourner par instance.
#
# Chaîne : Pangolin (terminal.marcpartensky.com, SSO)
#          -> newt (site tower)
#          -> 127.0.0.1:9121 (nginx, réécrit Host: 127.0.0.1:9120)
#          -> 127.0.0.1:9120 (hermes-backend.service, mode dashboard).
#
# Le backend bindé en loopback ne déclenche PAS la garde d'authentification du
# dashboard (elle ne s'active que sur une adresse non-loopback) : c'est le SSO
# Pangolin qui protège l'accès, exactement comme la ressource noVNC de tower.
# Ne JAMAIS exposer 9120 ou 9121 au firewall : /api/pty est un shell.
#
# ⚠ Le PTY hérite du durcissement de l'unité hermes-backend (User=hermes).
# Sans le `NoNewPrivileges = false` posé dans services/hermes/default.nix, le
# shell obtenu n'a aucun sudo, pas même le nixos-rebuild NOPASSWD.
{
  config,
  lib,
  ...
}: let
  backendPort = 9120;
  proxyPort = 9121;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  # Token de session stable : sans lui le backend en régénère un à chaque
  # démarrage, que personne d'autre ne peut connaître (donc aucun client
  # externe ne peut se rattacher à CE backend).
  sops.secrets."hermes_dashboard_token" = {
    sopsFile = ../../secrets/hermes-dashboard.yml;
    key = "hermes_dashboard_token";
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode = "0400";
  };

  services.hermes-agent.backend = {
    mode = "dashboard";
    host = "127.0.0.1";
    port = backendPort;
    sessionTokenFile = config.sops.secrets."hermes_dashboard_token".path;
  };

  # Proxy local : le backend refuse toute requête dont le Host diffère de
  # l'adresse sur laquelle il a bindé (défense anti-DNS-rebinding), d'où la
  # réécriture. Même mécanique que services/hermes-pocket.
  services.nginx.virtualHosts."hermes-dashboard-proxy" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    # `/` couvre l'app web, /api/ws et /api/pty ; proxyWebsockets pose les
    # en-têtes Upgrade/Connection dont le PTY a besoin.
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
  # NB : cle `proxy-resources` + `protocol` (schema attendu par le Pangolin du
  # VPS), cf. le commentaire detaille dans services/newt.
  services.newt.blueprint.proxy-resources.hermes-terminal = {
    name = "hermes-terminal";
    protocol = "http";
    full-domain = "terminal.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = proxyPort;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = proxyPort;
          path = "/";
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

  # Garde-fou : ces ports ne doivent jamais être ouverts sur le LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-dashboard : le port ${toString backendPort} (/api/pty = shell) ne doit pas être ouvert au firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-dashboard : le port ${toString proxyPort} (proxy du /api/pty) ne doit pas être ouvert au firewall.";
    }
  ];
}
