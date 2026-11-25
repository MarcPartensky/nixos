{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nginx.kasmvnc;
in {

  options.services.nginx.kasmvnc = {
    enable = mkEnableOption "nginx reverse proxy for KasmVNC";

    domain = mkOption {
      type = types.str;
      description = "Domain name (e.g. kasm.example.com)";
    };

    upstream = mkOption {
      type = types.str;
      default = "https://127.0.0.1:8443";
      description = "KasmVNC upstream (https://host:port)";
    };

    # ACME/Let's Encrypt
    acme = mkOption {
      type = types.bool;
      default = true;
    };

    # Local listen, for an exposure without ACME (reverse proxy that carries the
    # TLS, e.g. newt/Pangolin). listenPort = null keeps the nginx module
    # defaults (0.0.0.0:80 + 443 ssl).
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address when listenPort is set";
    };

    listenPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Local listen port (HTTP); null = nginx defaults (80/443)";
    };

    # WebSocket support for KasmVNC signaling
    websocket = mkOption {
      type = types.bool;
      default = true;
    };

    # Note: Full WebRTC UDP requires coturn or nginx stream module
    # This config handles HTTPS + WSS signaling only
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

          # Proxy HTTPS + WSS to KasmVNC
          locations."/" = {
            proxyPass = cfg.upstream;
            proxyWebsockets = cfg.websocket;
            # Same as rustguac: recommendedProxySettings already sets the headers and
            # proxy_http_version, a duplicate makes `nginx -t` fail.
            extraConfig = ''
              proxy_buffering off;
              proxy_read_timeout 86400;
              proxy_send_timeout 86400;
              # KasmVNC specific headers
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Server $host;
              ${cfg.extraConfig}
            '';
          };
        };
      };
    };

    # Note about WebRTC UDP
    # For full WebRTC (UDP media), you need either:
    # 1. Direct access to KasmVNC port (no nginx for UDP)
    # 2. coturn STUN/TURN server
    # 3. nginx stream module with UDP proxy (complex)
  };
}