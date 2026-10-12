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

    # Ecoute locale, pour une exposition sans ACME (typiquement derriere un
    # reverse proxy qui porte deja le TLS, ex. newt/Pangolin).
    # listenPort = null garde les defauts du module nginx (0.0.0.0:80 + 443 ssl).
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Adresse d'ecoute quand listenPort est defini";
    };

    listenPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Port d'ecoute local (HTTP) ; null = defauts nginx (80/443)";
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
            # recommendedProxySettings pose deja proxy_http_version, Upgrade,
            # Connection, Host, X-Real-IP, X-Forwarded-* (includes) : les
            # redeclarer fait echouer « nginx -t » (directive is duplicate) et
            # tombe TOUT nginx, donc tout ce qui est derriere. Ne garder ici que
            # ce que le module nginx ne pose pas.
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