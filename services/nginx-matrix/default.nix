# services/nginx-matrix/default.nix
# Nginx reverse proxy for Matrix client API + federation on deck.
# Terminates TLS (via Pangolin on VPS) and proxies to Conduit on localhost.
{ config, pkgs, lib, inputs, ... }: let
  domain = "matrix.marcpartensky.com";
  conduitPort = 6167;
  federationPort = 8448;
in {
  options.services.nginx-matrix = {
    enable = lib.mkEnableOption "Nginx reverse proxy for Matrix (Conduit)";
    domain = lib.mkOption {
      type = lib.types.str;
      default = domain;
      description = "Matrix server domain";
    };
    upstream_host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Conduit host";
    };
    upstream_port = lib.mkOption {
      type = lib.types.port;
      default = conduitPort;
      description = "Conduit client API port";
    };
    federation_port = lib.mkOption {
      type = lib.types.port;
      default = federationPort;
      description = "Federation port (inbound)";
    };
    listen_port = lib.mkOption {
      type = lib.types.port;
      default = 8008;
      description = "Local HTTP port for client API (Pangolin terminates TLS)";
    };
    acme = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable ACME (Let's Encrypt) - false when TLS is terminated by Pangolin";
    };
  };

  config = lib.mkIf config.services.nginx-matrix.enable {
    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      clientMaxBodySize = "100M";

      # Client API vhost (port 8008) - Pangolin terminates TLS on 443
      virtualHosts = {
        "${config.services.nginx-matrix.domain}" = {
          listen = [
            { addr = "127.0.0.1"; port = config.services.nginx-matrix.listen_port; }
          ];
          serverName = config.services.nginx-matrix.domain;
          root = "/var/www/empty";
          locations = {
            "/_matrix" = {
              proxyPass = "http://${config.services.nginx-matrix.upstream_host}:${toString config.services.nginx-matrix.upstream_port}";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_read_timeout 300s;
                proxy_send_timeout 300s;
                client_max_body_size 100M;
              '';
            };
            "/.well-known/matrix" = {
              proxyPass = "http://${config.services.nginx-matrix.upstream_host}:${toString config.services.nginx-matrix.upstream_port}";
              extraConfig = ''
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              '';
            };
          };
          # ACME disabled - TLS handled by Pangolin on VPS
          forceSSL = config.services.nginx-matrix.acme;
          enableACME = config.services.nginx-matrix.acme;
        };
      };
    };

    # Federation vhost (port 8448) - separate server block for inbound federation
    # Note: Federation uses the same domain but different port
    # Pangolin on VPS should route federation traffic to deck:8448
    systemd.services.nginx-matrix-federation = {
      description = "Nginx federation proxy for Matrix";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = [
          "${pkgs.nginx}/bin/nginx -t"
        ];
      };
      # The actual federation listener is configured via nginx virtualHosts below
      # This service just ensures nginx is reloaded after config changes
    };

    # Add federation listener to nginx
    services.nginx.virtualHosts."${config.services.nginx-matrix.domain}-federation" = {
      listen = [
        { addr = "0.0.0.0"; port = config.services.nginx-matrix.federation_port; }
      ];
      serverName = config.services.nginx-matrix.domain;
      root = "/var/www/empty";
      locations = {
        "/_matrix" = {
          proxyPass = "http://${config.services.nginx-matrix.upstream_host}:${toString config.services.nginx-matrix.upstream_port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            client_max_body_size 100M;
          '';
        };
        "/.well-known/matrix" = {
          proxyPass = "http://${config.services.nginx-matrix.upstream_host}:${toString config.services.nginx-matrix.upstream_port}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
      # No ACME - TLS terminated by Pangolin
      forceSSL = false;
      enableACME = false;
    };

    # Open firewall for federation port (inbound from other servers)
    networking.firewall.allowedTCPPorts = [
      config.services.nginx-matrix.federation_port
    ];

    # Ensure www directory exists
    systemd.tmpfiles.rules = [
      "d /var/www/empty 0755 root root -"
    ];
  };
}