{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nginx.rustguac;
in {

  options.services.nginx.rustguac = {
    enable = mkEnableOption "nginx reverse proxy for rustguac";

    domain = mkOption {
      type = types.str;
      description = "Domain name (e.g. guac.example.com)";
    };

    upstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8089";
      description = "rustguac upstream (protocol://host:port)";
    };

    # ACME/Let's Enccrypt (uses global security.acme.email)
    acme = mkOption {
      type = types.bool;
      default = true;
      description = "Enable ACME/Let's Encrypt";
    };

    # WebSocket support
    websocket = mkOption {
      type = types.bool;
      default = true;
      description = "Enable WebSocket proxying for Guacamole protocol";
    };

    # Extra nginx config
    extraConfig = mkOption { type = types.str; default = ""; };
  };

  config = mkIf cfg.enable {
    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;

      virtualHosts = {
        "${cfg.domain}" = {
          forceSSL = cfg.acme;
          enableACME = cfg.acme;

          locations."/" = {
            proxyPass = cfg.upstream;
            proxyWebsockets = cfg.websocket;
            extraConfig = ''
              proxy_buffering off;
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_read_timeout 86400;
              proxy_send_timeout 86400;
              ${cfg.extraConfig}
            '';
          };
        };
      };
    };
  };
}