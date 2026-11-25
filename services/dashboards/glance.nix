# Glance : un binaire Go, page unique de signets groupés (le plus épuré).
{
  lib,
  pkgs,
  config,
  ...
}: let
  domain = "glance.marcpartensky.com";
  appPort = 8613;
  port = 8673;
in {
  services.glance = {
    enable = true;
    settings = {
      server = {
        host = "127.0.0.1";
        port = appPort;
      };
      pages = [
        {
          name = "Homelab";
          columns = [
            {
              size = "full";
              widgets = [
                {
                  type = "bookmarks";
                  groups = [
                  {
                    title = "Média";
                    links = [
                    {
                      title = "Jellyfin";
                      url = "https://jellyfin.marcpartensky.com";
                      icon = "si:jellyfin";
                    }
                    {
                      title = "Audiobookshelf";
                      url = "https://audiobookshelf.marcpartensky.com";
                      icon = "si:audiobookshelf";
                    }
                    {
                      title = "Sonarr";
                      url = "https://sonarr.marcpartensky.com";
                      icon = "si:sonarr";
                    }
                    {
                      title = "Radarr";
                      url = "https://radarr.marcpartensky.com";
                      icon = "si:radarr";
                    }
                    {
                      title = "qBittorrent";
                      url = "https://torrent.marcpartensky.com";
                      icon = "si:qbittorrent";
                    }
                    ];
                  }
                  {
                    title = "Fichiers";
                    links = [
                    {
                      title = "Nextcloud";
                      url = "https://cloud.marcpartensky.com";
                      icon = "si:nextcloud";
                    }
                    {
                      title = "Syncthing";
                      url = "https://syncthing.marcpartensky.com";
                      icon = "si:syncthing";
                    }
                    {
                      title = "RustFS";
                      url = "https://rustfs.marcpartensky.com";
                      icon = "si:rustfs";
                    }
                    {
                      title = "MinIO";
                      url = "https://store.marcpartensky.com";
                      icon = "si:minio";
                    }
                    {
                      title = "Fichier";
                      url = "https://fichier.marcpartensky.com";
                      icon = "si:filebrowser";
                    }
                    {
                      title = "Droplify";
                      url = "https://drop.marcpartensky.com";
                      icon = "si:dropbox";
                    }
                    ];
                  }
                  {
                    title = "Agent";
                    links = [
                    {
                      title = "Hermes";
                      url = "https://hermes.marcpartensky.com";
                      icon = "si:openai";
                    }
                    {
                      title = "Terminal";
                      url = "https://terminal.marcpartensky.com";
                      icon = "si:gnometerminal";
                    }
                    {
                      title = "Hermes Mobile";
                      url = "https://hermes-mobile.marcpartensky.com";
                      icon = "si:android";
                    }
                    {
                      title = "Hermes Anna";
                      url = "https://hermes-anna.marcpartensky.com";
                      icon = "si:openai";
                    }
                    {
                      title = "Hermes Yves";
                      url = "https://hermes-yves.marcpartensky.com";
                      icon = "si:openai";
                    }
                    {
                      title = "Open Notebook";
                      url = "https://notebook.marcpartensky.com";
                      icon = "si:jupyter";
                    }
                    {
                      title = "n8n";
                      url = "https://n8n.marcpartensky.com";
                      icon = "si:n8n";
                    }
                    {
                      title = "Matrix";
                      url = "https://matrix.marcpartensky.com";
                      icon = "si:matrix";
                    }
                    ];
                  }
                  {
                    title = "Développement";
                    links = [
                    {
                      title = "Gitea";
                      url = "https://git.marcpartensky.com";
                      icon = "si:gitea";
                    }
                    {
                      title = "JupyterHub";
                      url = "https://lab.marcpartensky.com";
                      icon = "si:jupyter";
                    }
                    {
                      title = "Taskq";
                      url = "https://taskq.marcpartensky.com";
                      icon = "si:gnubash";
                    }
                    {
                      title = "Winnie";
                      url = "https://winnie.marcpartensky.com";
                      icon = "si:vite";
                    }
                    {
                      title = "Winnie API";
                      url = "https://api.winnie.marcpartensky.com";
                      icon = "si:fastapi";
                    }
                    {
                      title = "RentScout";
                      url = "https://rentscout.marcpartensky.com";
                      icon = "si:googlemaps";
                    }
                    {
                      title = "Backtest";
                      url = "https://backtest.marcpartensky.com";
                      icon = "si:tradingview";
                    }
                    {
                      title = "CV";
                      url = "https://cv.marcpartensky.com";
                      icon = "si:googledocs";
                    }
                    ];
                  }
                  {
                    title = "Bureaux distants";
                    links = [
                    {
                      title = "Kasm";
                      url = "https://kasm.marcpartensky.com";
                      icon = "si:kasm";
                    }
                    {
                      title = "Android";
                      url = "https://android.marcpartensky.com";
                      icon = "si:android";
                    }
                    {
                      title = "VNC";
                      url = "https://vnc.marcpartensky.com";
                      icon = "si:gnometerminal";
                    }
                    {
                      title = "Guacamole";
                      url = "https://guac.marcpartensky.com";
                      icon = "si:guacamole";
                    }
                    ];
                  }
                  {
                    title = "Système";
                    links = [
                    {
                      title = "Glances";
                      url = "https://proc.marcpartensky.com";
                      icon = "si:glances";
                    }
                    {
                      title = "Zitadel";
                      url = "https://auth.marcpartensky.com";
                      icon = "si:zitadel";
                    }
                    {
                      title = "Pangolin";
                      url = "https://pangolin.marcpartensky.com";
                      icon = "si:pangolin";
                    }
                    {
                      title = "Traefik";
                      url = "https://traefik.marcpartensky.com";
                      icon = "si:traefik";
                    }
                    {
                      title = "Headscale";
                      url = "https://ts.marcpartensky.com";
                      icon = "si:tailscale";
                    }
                    {
                      title = "Gotify";
                      url = "https://gotify.marcpartensky.com";
                      icon = "si:gotify";
                    }
                    {
                      title = "Anki";
                      url = "https://anki.marcpartensky.com";
                      icon = "si:anki";
                    }
                    {
                      title = "Vaultwarden";
                      url = "https://vault.marcpartensky.com";
                      icon = "si:vaultwarden";
                    }
                    {
                      title = "Stalwart";
                      url = "https://mail.marcpartensky.com";
                      icon = "si:maildotru";
                    }
                    {
                      title = "Legal";
                      url = "https://legal.marcpartensky.com";
                      icon = "si:linktree";
                    }
                    ];
                  }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # systemd ne surveille pas /run/glance/glance.yaml (config écrite par le
  # pre-start) : une empreinte en store path force le redémarrage quand la
  # configuration change.
  systemd.services.glance.restartTriggers = [
    (pkgs.writeText "glance-settings-fingerprint" (builtins.toJSON config.services.glance.settings))
  ];

  services.nginx.virtualHosts."${domain}" = {
    listen = [{
      addr = "127.0.0.1";
      port = port;
    }];
    serverName = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString appPort}";
      proxyWebsockets = true;
    };
  };
}
