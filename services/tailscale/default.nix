{ config, lib, pkgs, ... }:
let
  cfg = config.meshTailscale;
  routesArg = lib.concatStringsSep "," cfg.advertiseRoutes;
  setFlags = [
    "--advertise-exit-node=${lib.boolToString cfg.advertiseExitNode}"
    # une valeur vide efface les routes annoncées précédemment (idempotence :
    # un nœud qui ne doit plus annoncer est activement nettoyé)
    "--advertise-routes=${routesArg}"
  ];
in
{
  # Nœud tailscale du mesh headscale de marc (voir services/headscale pour le
  # contrôleur, qui tourne sur le VPS `anywhere`). À importer sur chaque machine
  # NixOS du flake : tower, deck, anywhere, laptop...
  #
  # Enrôlement automatique : clé de pré-authentification réutilisable commune,
  # dans secrets/headscale.yml (clé `preauth_key` ; destinataires anywhere,
  # tower, mac, deck-host). Rotation : voir le bas du module headscale.
  #
  # Durcissement : disableUpstreamLogging coupe l'envoi de logs de tailscaled
  # vers Tailscale Inc (équivalent de --no-logs-no-support) ; le contrôleur
  # n'annonce que le DERP du VPS, jamais la flotte tailscale.com.
  #
  # Exit node / sous-réseaux : c'est PAR HÔTE, via les options meshTailscale.
  # Les routes annoncées doivent ensuite être approuvées côté contrôleur :
  #   headscale nodes approve-routes --identifier <id> --routes 0.0.0.0/0,::/0,192.168.1.0/24
  options.meshTailscale = {
    advertiseExitNode = lib.mkEnableOption "annoncer ce nœud comme exit node du tailnet";
    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Sous-réseaux annoncés au tailnet (ex. le LAN maison depuis tower).";
    };
  };

  config = {
    # Piège du premier enrôlement : tailscaled-autoconnect.service a 90 s pour
    # joindre le contrôleur. Si l'endpoint public n'est pas encore prêt (cert
    # Traefik en cours d'émission, route absente), il part en timeout et le nœud
    # reste non enrôlé. Une fois l'endpoint OK :
    #   sudo systemctl restart tailscaled-autoconnect.service   (ou un reboot)
    sops.secrets."headscale/preauth_key" = {
      sopsFile = ../../secrets/headscale.yml;
      key = "preauth_key";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault 1;

    services.tailscale = {
      enable = true;
      openFirewall = true;
      # "both" : ce nœud peut aussi annoncer des sous-réseaux / être exit node.
      useRoutingFeatures = "both";
      authKeyFile = config.sops.secrets."headscale/preauth_key".path;
      extraUpFlags = [
        "--login-server=https://headscale.marcpartensky.com" # contrôleur auto-hébergé, pas Tailscale Inc
        "--accept-routes"
      ]
      ++ lib.optional cfg.advertiseExitNode "--advertise-exit-node"
      ++ lib.optional (cfg.advertiseRoutes != [ ]) "--advertise-routes=${routesArg}";
      disableUpstreamLogging = true;
    };

    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # Les flags passés à `tailscale up` ne sont appliqués par
    # tailscaled-autoconnect qu'au moment d'un login : sur un nœud déjà connecté
    # il faut `tailscale set`. Cette unité rend l'annonce déclarative et
    # idempotente, réappliquée à chaque démarrage.
    systemd.services.tailscale-advertise = {
      description = "Tailscale : annonce exit node / sous-réseaux";
      wantedBy = [ "multi-user.target" ];
      requires = [ "tailscaled.service" ];
      after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
      wants = [ "tailscaled-autoconnect.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.services.tailscale.package}/bin/tailscale set ${lib.concatStringsSep " " setFlags}";
      };
    };
  };
}
