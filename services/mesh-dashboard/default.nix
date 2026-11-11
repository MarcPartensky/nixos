# services/mesh-dashboard : page des nœuds du tailnet (headscale) de marc.
#
# Chaîne : Pangolin (mesh.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9140 (ce service).
# Depuis le tailnet, l'URL directe est http://100.64.0.3:9140 (pas de SSO :
# tailscale0 est déjà une interface de confiance, cf. services/tailscale).
#
# Source de vérité : `tailscale status --json` lu par le client de tower, plus
# `tailscale ping` pour le chemin réel de chaque pair (direct vs DERP). Rien
# n'est stocké : la page est un reflet de l'état courant du contrôleur.
#
# Le service tourne en utilisateur système dédié, sans capacité et avec un
# système de fichiers en lecture seule (seul /var/run/tailscale est monté en
# écriture pour le socket du démon). Il ne fait que lire : aucune écriture
# n'est nécessaire.
{ config, lib, pkgs, ... }:
let
  port = 9140;

  # Jeton d'application Gotify pour les alertes de transition (nœud hors ligne
  # / de retour). Le jeton vit dans son propre fichier sops, chiffré vers tower
  # seulement, et il est OPTIONNEL : tant que le fichier n'existe pas, le module
  # se déploie quand même (le dashboard mesure, mais ne notifie pas, et l'affiche
  # dans l'en-tête « Gotify : jeton manquant »).
  #
  # Créer le jeton : Gotify (https://gotify.marcpartensky.com, connexion OIDC)
  # -> Apps -> Create Application -> nom « mesh-dashboard », puis :
  #   printf 'mesh_token: %s\n' '<jeton>' | sops --encrypt \
  #     --filename-override secrets/gotify-mesh.yml --input-type yaml \
  #     /dev/stdin > secrets/gotify-mesh.yml
  # (règle `path_regex: secrets/gotify-mesh\.yml$` dans .sops.yaml)
  gotifySecretFile = ../../secrets/gotify-mesh.yml;
  gotifyTokenAvailable = builtins.pathExists gotifySecretFile;
  gotifyTokenPath = "/run/secrets/gotify/mesh_token";
in
{
  users.users.mesh-dash = {
    isSystemUser = true;
    group = "mesh-dash";
    description = "Dashboard du tailnet (lecture de tailscaled)";
  };
  users.groups.mesh-dash = { };

  sops.secrets = lib.mkIf gotifyTokenAvailable {
    "gotify/mesh_token" = {
      sopsFile = gotifySecretFile;
      key = "mesh_token";
      owner = "mesh-dash";
      group = "mesh-dash";
      mode = "0400";
    };
  };

  systemd.services.mesh-dashboard = {
    description = "Dashboard des nœuds du tailnet (headscale)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" ];
    after = [ "network.target" "tailscaled.service" ];

    # `tailscale` doit être dans le PATH de l'unité : le script l'appelle en
    # subprocess (status + ping).
    path = [ pkgs.tailscale ];

    serviceConfig = {
      Type = "simple";
      User = "mesh-dash";
      Group = "mesh-dash";
      Environment = [
        "MESH_DASHBOARD_HOST=0.0.0.0"
        "MESH_DASHBOARD_PORT=${toString port}"
        "MESH_DASHBOARD_STATE=/var/lib/mesh-dashboard/state.json"
        # Gotify tourne sur tower en loopback : aucune sortie réseau nécessaire.
        "MESH_DASHBOARD_GOTIFY_URL=http://127.0.0.1:8070"
        # Appareils à enrôler dans le tailnet : affichés « en attente » tant
        # qu'ils ne sont pas vus par le contrôleur. `phone` = Xiaomi de marc
        # (app Tailscale Android, serveur alternatif headscale), `tablet` =
        # tablette Nix-on-Droid à venir.
        "MESH_DASHBOARD_EXPECTED=phone,tablet"
      ]
      ++ lib.optional gotifyTokenAvailable "MESH_DASHBOARD_GOTIFY_TOKEN_FILE=${gotifyTokenPath}";

      # État persistant : « vu en ligne pour la dernière fois à » survit ainsi à
      # un redémarrage du service (le dossier est créé et chowné par systemd).
      StateDirectory = "mesh-dashboard";
      StateDirectoryMode = "0750";
      ExecStart = "${pkgs.python3}/bin/python3 ${./mesh_dashboard.py}";
      Restart = "always";
      RestartSec = 3;

      # Durcissement : le service ne lit qu'un socket et ne sert que du HTTP.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      # Le socket du démon tailscale (srw-rw-rw-, cf. tailscaled) : lecture et
      # connexion ; l'état persistant du dashboard (StateDirectory) est le seul
      # autre chemin inscriptible.
      ReadWritePaths = [ "/var/run/tailscale" "/var/lib/mesh-dashboard" ];
    };
  };

  # Le port reste fermé au firewall : on y accède par le tailnet (interface
  # tailscale0 de confiance) ou par le SSO Pangolin via newt, jamais en clair
  # depuis le LAN.
  services.newt.blueprint.proxy-resources.mesh-dashboard = {
    name = "mesh-dashboard";
    protocol = "http";
    full-domain = "mesh.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
          path = "/healthz";
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

  assertions = [
    {
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "mesh-dashboard : le port ${toString port} ne doit pas être ouvert au firewall (accès tailnet + SSO Pangolin uniquement).";
    }
  ];
}
