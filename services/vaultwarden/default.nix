{pkgs, ...}: {
  services.postgresql = {
    ensureDatabases = ["vaultwarden"];
    ensureUsers = [
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
        # Since you use 'trust' in authentication below, we don't strictly need a password here
        # provided Nextcloud connects from localhost.
      }
    ];
  };

  # services.nginx = {
  #   enable = true;
  #   virtualHosts."vaultwarden.local" = {
  #     forceSSL = true;
  #     sslCertificate = "/etc/ssl/vaultwarden/cert.pem";
  #     sslCertificateKey = "/etc/ssl/vaultwarden/key.pem";
  #     locations."/" = {
  #       proxyPass = "http://0.0.0.0:8222";
  #       proxyWebsockets = true;
  #       extraConfig = ''
  #         proxy_set_header Host $host;
  #         proxy_set_header X-Real-IP $remote_addr;
  #         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  #         proxy_set_header X-Forwarded-Proto $scheme;
  #       '';
  #     };
  #   };
  # };
  services.nginx = {
    enable = true;
    virtualHosts."localhost" = {
      sslCertificate = ./localhost.crt;
      sslCertificateKey = ./certs/localhost.key; # via sops-nix idéalement
      listen = [
        {
          addr = "127.0.0.1";
          port = 8843;
          ssl = true;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8083";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Real-IP $remote_addr;
        '';
      };
      locations."/notifications/hub" = {
        proxyPass = "http://127.0.0.1:3012";
        proxyWebsockets = true;
      };
    };
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    # domain = "http://localhost:8083";
    # backupDir = "/srv/vaultwarden/backup";
    config = {
      # DOMAIN = "http://0.0.0.0:8083";
      DOMAIN = "https://vault.marcpartensky.com";
      SIGNUPS_ALLOWED = true;
      DATABASE_URL = "postgres://vaultwarden:vaultwardenpassword@localhost:5432/vaultwarden";

      WEBSOCKET_ENABLED = true;
      WEBSOCKET_ADDRESS = "0.0.0.0";
      WEBSOCKET_PORT = 3012;

      # Serveur HTTP principal
      # ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = 8083;
    };
  };
}
