# services/tunnel-health : sante des alias SSH et des tunnels inverses de marc.
#
# Chaine : Pangolin (tunnel.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9144 (tunnel-health-web).
#
# Deux unites, deux utilisateurs :
#
#   tunnel-health-probe  (User=hermes, timer 60 s) : une seule connexion ssh
#     vers le VPS pour lire la banniere SSH des ports inverses en loopback
#     (2222/2223/2224/2226), plus les alias LAN directement. Ecrit
#     /var/lib/tunnel-health/{status.json,index.html}. Tourne en hermes parce
#     que c'est le compte qui a deja la cle root du VPS : aucune cle
#     supplementaire ni ligne authorized_keys a ajouter cote VPS.
#
#   tunnel-health-web    (User=tunnel-health, lecture seule) : sert la page sur
#     la loopback. Le serveur HTTP n'a donc aucun acces ssh : un bug de parsing
#     ne donne pas le VPS.
#
# Rien n'est ouvert au firewall : l'acces passe par newt + SSO Pangolin.
{ config, lib, pkgs, ... }:
let
  port = 9144;

  # `via` = chemin de la mesure :
  #   lan    connexion directe depuis tower (LAN maison, sans mesh)
  #   local  loopback de tower (points d'entree wstunnel)
  #   rack   une seule session ssh vers le VPS, puis /dev/tcp sur sa loopback :
  #          c'est le seul endroit d'ou les tunnels inverses sont visibles.
  endpoints = [
    {
      alias = "towerlocal";
      via = "lan";
      host = "192.168.1.44";
      port = 22;
      target = "192.168.1.44:22";
      user = "marc";
      purpose = "tower sur le LAN, si le mesh est down";
    }
    {
      alias = "maclan";
      via = "lan";
      host = "192.168.1.48";
      port = 22;
      target = "192.168.1.48:22";
      user = "marc";
      purpose = "Mac sur le LAN (IP DHCP, peut bouger)";
    }
    {
      alias = "mactun";
      via = "rack";
      port = 2223;
      target = "rack:2223";
      user = "marc";
      purpose = "Mac par son tunnel inverse autossh (launchd)";
    }
    {
      alias = "phonetun";
      via = "rack";
      port = 2224;
      target = "rack:2224";
      user = "nix-on-droid";
      purpose = "telephone par son tunnel inverse (-> 8023)";
    }
    {
      alias = "tunnel";
      via = "rack";
      port = 2222;
      target = "rack:2222";
      user = "marc";
      purpose = "tower par son tunnel inverse autossh (-> 22), pas wstunnel";
    }
    {
      alias = "vpsws";
      via = "local";
      port = 2222;
      target = "127.0.0.1:2222 (tower)";
      user = "root";
      purpose = "VPS par wstunnel : client absent de tower, alias mort";
    }
    {
      alias = "phonews";
      via = "local";
      port = 2225;
      target = "127.0.0.1:2225 (tower)";
      user = "nix-on-droid";
      purpose = "telephone par le meme wstunnel : client absent";
    }
    {
      alias = "tablet";
      via = "rack";
      port = 2226;
      target = "rack:2226";
      user = "nix-on-droid";
      purpose = "tablette nix-on-droid, son propre tunnel";
    }
  ];

  endpointsFile = pkgs.writeText "tunnel-health-endpoints.json" (builtins.toJSON endpoints);
  script = ./tunnel_health.py;

  # Durcissement commun aux deux unites.
  hardening = {
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
  };
in
{
  users.users.tunnel-health = {
    isSystemUser = true;
    group = "tunnel-health";
    description = "Sert la page de sante des tunnels (lecture seule)";
  };
  users.groups.tunnel-health = { };

  systemd.services.tunnel-health-probe = {
    description = "Sonde de sante des alias SSH et des tunnels inverses";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.openssh ];

    serviceConfig = hardening // {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      # HOME est necessaire au client ssh ; la cle vit dans son ~/.ssh.
      Environment = [
        "HOME=/var/lib/hermes"
        "TUNNEL_HEALTH_DIR=/var/lib/tunnel-health"
        "TUNNEL_HEALTH_ENDPOINTS=${endpointsFile}"
        "TUNNEL_HEALTH_RACK_HOST=root@marcpartensky.com"
        "TUNNEL_HEALTH_SSH_KEY=/var/lib/hermes/.ssh/id_ed25519"
        "TUNNEL_HEALTH_KNOWN_HOSTS=/var/lib/hermes/.ssh/known_hosts"
      ];
      StateDirectory = "tunnel-health";
      # 0755 : l'unite web (autre utilisateur) doit pouvoir lire le snapshot.
      StateDirectoryMode = "0755";
      ExecStart = "${pkgs.python3}/bin/python3 ${script} probe";
      TimeoutStartSec = "45s";
      # Sortie non nulle = au moins un alias tombe ; ce n'est pas une panne de
      # l'unite (le timer doit continuer a mesurer), donc pas de Restart.
      SuccessExitStatus = "0 1";
    };
  };

  systemd.timers.tunnel-health-probe = {
    description = "Sonde de sante des tunnels toutes les 60 s";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20s";
      OnUnitInactiveSec = "60s";
      AccuracySec = "5s";
      Unit = "tunnel-health-probe.service";
    };
  };

  systemd.services.tunnel-health-web = {
    description = "Page de sante des tunnels (loopback, derriere Pangolin)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = hardening // {
      Type = "simple";
      User = "tunnel-health";
      Group = "tunnel-health";
      Environment = [
        "TUNNEL_HEALTH_DIR=/var/lib/tunnel-health"
        "TUNNEL_HEALTH_PORT=${toString port}"
      ];
      ExecStart = "${pkgs.python3}/bin/python3 ${script} web --host 127.0.0.1 --port ${toString port}";
      Restart = "always";
      RestartSec = 3;
      # Lecture seule du snapshot ecrit par la sonde ; le "-" tolere le dossier
      # absent au tout premier demarrage.
      ReadOnlyPaths = [ "-/var/lib/tunnel-health" ];
    };
  };

  # La page n'est joignable que par newt (SSO Pangolin) : jamais en clair.
  services.newt.blueprint.proxy-resources.tunnel-health = {
    name = "tunnel-health";
    protocol = "http";
    full-domain = "tunnel.marcpartensky.com";
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
      message = "tunnel-health : le port ${toString port} ne doit pas etre ouvert au firewall (newt + SSO uniquement).";
    }
  ];
}
