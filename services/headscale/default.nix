{ pkgs, config, ... }:
{
  # Contrôleur du mesh headscale de marc (version DURCIE).
  #
  # Tourne sur le VPS `anywhere`, seul hôte à IP publique stable, et sert :
  #   - la coordination des nœuds tailscale (tower, deck, anywhere, laptop...) ;
  #   - un DERP embarqué : relais chiffré de secours quand le hole punching
  #     échoue. Le trafic y circule en WireGuard, le relais ne déchiffre rien.
  #
  # Durcissement (par rapport au tailscale.com public) :
  #   - derp.urls = [] : la flotte DERP de Tailscale Inc est retirée de la carte
  #     annoncée aux clients ; le seul relais est celui de ce VPS, qui fait
  #     partie du réseau. Aucune machine extérieure ne voit les IP des nœuds.
  #   - logtail.enabled = false : aucun log client n'est envoyé à Tailscale Inc.
  #
  # Côté clients : services/tailscale/default.nix, à importer sur chaque machine
  # NixOS du flake.
  #
  # Exposition : headscale.marcpartensky.com -> Traefik local (Pangolin) ->
  # 127.0.0.1:8090 en HTTP ; la route est dans services/traefik/dynamic.toml.
  # Le DERP embarqué passe par le MÊME endpoint HTTPS (/derp), donc par
  # Traefik ; seul le STUN (UDP 3478) est exposé en direct, un reverse proxy
  # ne portant pas l'UDP.
  #
  # Bootstrap / rotation : voir en bas du fichier.
  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = 8090;
    settings = {
      # URL publique que les clients utilisent pour rejoindre le tailnet.
      server_url = "https://headscale.marcpartensky.com";
      # Traefik tourne en local sur ce VPS : honorer ses X-Forwarded-*.
      trusted_proxies = [ "127.0.0.1/32" ];

      derp = {
        # Aucune carte DERP extérieure : uniquement le DERP embarqué ci-dessous.
        urls = [ ];
        paths = [ ];
        auto_update_enabled = false;
        server = {
          enabled = true;
          region_id = 900; # hors plage des régions officielles (1-30)
          region_code = "vps";
          region_name = "VPS RackNerd";
          # STUN : aide au hole punching, en UDP direct sur l'IP publique.
          stun_listen_addr = "0.0.0.0:3478";
          # La région du DERP embarqué est ajoutée à la carte automatiquement,
          # annoncée sur server_url (port 443, via Traefik).
          automatically_add_embedded_derp_region = true;
          # Seuls les nœuds du tailnet peuvent utiliser ce relais.
          verify_clients = true;
          # private_key_path : défaut du module
          # (/var/lib/headscale/derp_server_private.key, généré au premier boot)
        };
      };

      # ACL depuis un fichier HuJSON (mode "file").
      policy = {
        mode = "file";
        path = ./policy.hujson;
      };

      # Aucun log client vers Tailscale Inc (défaut de 0.28, explicité ici).
      logtail.enabled = false;

      dns = {
        magic_dns = true;
        base_domain = "ts.marcpartensky.com";
        nameservers.global = [ "1.1.1.1" "9.9.9.9" ];
        override_local_dns = false;
      };
    };
  };

  environment.systemPackages = [ config.services.headscale.package ];

  # STUN du DERP embarqué : UDP en direct, Traefik ne porte pas l'UDP.
  networking.firewall.allowedUDPPorts = [ 3478 ];
}

# ================================ BOOTSTRAP ================================
#
# Déjà en place (23/10/2026) :
#   - utilisateur headscale `marc` (id 1) ;
#   - clé de pré-authentification réutilisable (expiration 10 ans, id 2),
#     chiffrée dans secrets/headscale.yml (clé `preauth_key`), consommée par
#     services/tailscale sur chaque machine.
#
# Rotation / nouvelle clé (après révocation par exemple) :
#   sudo headscale users list                          # retrouver l'id de marc
#   sudo headscale preauthkeys create -u <id> --reusable --expiration 0
#   # remplacer preauth_key dans secrets/headscale.yml (sops), redéployer.
#
# Révocation d'un nœud : sudo headscale nodes delete -i <id> (ou nodes expire
# pour forcer une réauthentification).
#
# Les nœuds n'expirent pas (Expiration 0001-01-01 dans `nodes list`) ; en
# poser une si voulu :
#   sudo headscale nodes expire -i <id> -e 2036-01-01T00:00:00Z
