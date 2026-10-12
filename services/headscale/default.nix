{ pkgs, config, ... }:
{
  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = 8090;
    settings = {
      # URL publique que les clients Tailscale utiliseront pour rejoindre le tailnet.
      # headscale.marcpartensky.com doit pointer vers CE VPS et être routé (Pangolin)
      # vers 127.0.0.1:8090 en HTTP.
      server_url = "https://headscale.marcpartensky.com";
      # Le reverse proxy (Pangolin/Traefik) tourne en local sur ce VPS : on honore
      # ses en-têtes X-Forwarded-* pour logguer la vraie IP source des clients.
      trusted_proxies = [ "127.0.0.1/32" ];

      # DERP : flotte publique Tailscale par défaut pour le fallback derrière NAT
      # (fonctionne out-of-the-box). Le data plane reste du WireGuard chiffré; le
      # relais ne voit que des paquets qu'il ne peut pas déchiffrer. Pour une
      # souveraineté totale plus tard : activer derp.server (embarqué) + exposer
      # STUN, cf. docs headscale (exige server_url en https et TLS terminé par
      # headscale lui-même, pas via reverse proxy).

      # Politique ACL depuis un fichier HuJSON (mode "file").
      policy = {
        mode = "file";
        path = ./policy.hujson;
      };

      # Ne jamais envoyer les logs clients vers Tailscale Inc.
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
}
