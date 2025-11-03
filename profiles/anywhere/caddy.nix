{ pkgs, ... }: {
  services.caddy = {
    enable = true;
    package = pkgs.caddy;  # ou caddyCustom si plugins
    config = ''
      vault.marcpartensky.com {
        reverse_proxy localhost:8080
        header {
          X‑Frame‑Options "SAMEORIGIN"
          Strict‑Transport‑Security "max‑age=31536000; includeSubDomains; preload"
        }
      }
    '';
  };
}
