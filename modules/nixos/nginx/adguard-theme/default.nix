{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nginx.adguardTheme;
in {
  options.services.nginx.adguardTheme = {
    enable = mkEnableOption "le thème Catppuccin Mocha devant l'UI d'AdGuard Home";

    listenAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1" ];
      description = ''
        Adresses d'écoute du vhost. Le résolveur lui-même n'écoute que sur
        webHost (loopback par défaut) : ce vhost est la seule façon d'ouvrir
        l'UI thémée sur le mesh.
      '';
    };

    listenPort = mkOption {
      type = types.port;
      default = 3021;
      description = "Port HTTP du vhost (TLS reste porté par Pangolin/newt).";
    };

    upstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:3000";
      description = "UI d'AdGuard Home à proxifier (services.dnsFilter.webPort).";
    };

    themeFile = mkOption {
      type = types.path;
      default = ./catppuccin-mocha.css;
      description = "Feuille de style injectée dans le HTML d'AdGuard.";
    };
  };

  config = mkIf cfg.enable {
    services.nginx.virtualHosts."adguard-theme" = {
      # TLS terminé en amont : nginx ne sert que du HTTP local.
      listen = map (addr: {
        inherit addr;
        port = cfg.listenPort;
        ssl = false;
      }) cfg.listenAddresses;

      locations = {
        "/" = {
          proxyPass = cfg.upstream;
          # recommendedProxySettings pose déjà Host/X-Real-IP/proxy_http_version :
          # un doublon fait échouer `nginx -t` (leçon du module kasmvnc).
          extraConfig = ''
            # Le filtre sub_filter travaille sur du texte : on refuse la
            # compression amont, sinon rien n'est remplacé (et le HTML part
            # tel quel, ce qui donne un thème silencieusement absent).
            proxy_set_header Accept-Encoding "";
            sub_filter_types text/html;
            sub_filter_once on;
            sub_filter '</head>' '<link rel="stylesheet" href="/__catppuccin.css"></head>';
          '';
        };

        # La feuille est servie par nginx, pas par AdGuard : aucun fichier du
        # paquet n'est modifié, et un rebuild d'AdGuard ne casse pas le thème.
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
