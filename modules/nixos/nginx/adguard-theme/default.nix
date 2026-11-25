{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nginx.adguardTheme;
in {
  options.services.nginx.adguardTheme = {
    enable = mkEnableOption "the Catppuccin Mocha theme in front of the AdGuard Home UI";

    listenAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1" ];
      description = ''
        Listen addresses of the vhost. The resolver itself only listens on
        webHost (loopback by default): this vhost is the only way to open
        the themed UI on the mesh.
      '';
    };

    listenPort = mkOption {
      type = types.port;
      default = 3021;
      description = "HTTP port of the vhost (TLS is still handled by Pangolin/newt).";
    };

    upstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:3000";
      description = "AdGuard Home UI to proxy (services.dnsFilter.webPort).";
    };

    themeFile = mkOption {
      type = types.path;
      default = ./catppuccin-mocha.css;
      description = "Stylesheet injected into the AdGuard HTML.";
    };
  };

  config = mkIf cfg.enable {
    services.nginx.virtualHosts."adguard-theme" = {
      # TLS terminated upstream: nginx only serves local HTTP.
      listen = map (addr: {
        inherit addr;
        port = cfg.listenPort;
        ssl = false;
      }) cfg.listenAddresses;

      locations = {
        "/" = {
          proxyPass = cfg.upstream;
          # recommendedProxySettings already sets Host/X-Real-IP/proxy_http_version:
          # a duplicate makes `nginx -t` fail (lesson from the kasmvnc module).
          extraConfig = ''
            # The sub_filter filter works on text: we refuse upstream
            # compression, otherwise nothing is replaced (and the HTML goes
            # out as is, which gives a silently missing theme).
            proxy_set_header Accept-Encoding "";
            sub_filter_types text/html;
            sub_filter_once on;
            sub_filter '</head>' '<link rel="stylesheet" href="/__catppuccin.css"></head>';
          '';
        };

        # The stylesheet is served by nginx, not by AdGuard: no file of the
        # package is modified, and an AdGuard rebuild does not break the theme.
        "= /__catppuccin.css" = {
          alias = cfg.themeFile;
          extraConfig = ''
            default_type text/css;
            add_header Cache-Control "max-age=600";
          '';
        };
      };
    };
  };
}
