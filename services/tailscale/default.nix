{ config, lib, pkgs, ... }:
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
    ];
    disableUpstreamLogging = true;
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
