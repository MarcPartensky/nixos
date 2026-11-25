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

    # ACME/Let's Enccrypt (uses security.acme.defaults.email)
    acme = mkOption {
      type = types.bool;
      default = true;
      description = "Enable ACME/Let's Encrypt";
    };

    # Local listen, for an exposure without ACME (typically behind a
    # reverse proxy that already carries the TLS, e.g. newt/Pangolin).
    # listenPort = null keeps the nginx module defaults (0.0.0.0:80 + 443 ssl).
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address when listenPort is defined";
    };

    listenPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Local listen port (HTTP); null = nginx defaults (80/443)";
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
          listen = optional (cfg.listenPort != null) {
            addr = cfg.listenAddress;
            port = cfg.listenPort;
          };

          locations."/" = {
            proxyPass = cfg.upstream;
            proxyWebsockets = cfg.websocket;
            # recommendedProxySettings already sets proxy_http_version, Upgrade,
            # Connection, Host, X-Real-IP, X-Forwarded-* (includes): redeclaring
            # them makes "nginx -t" fail (directive is duplicate) and
            # takes down ALL nginx, hence everything behind it. Keep here only
            # what the nginx module does not set.
            extraConfig = ''
              proxy_buffering off;
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