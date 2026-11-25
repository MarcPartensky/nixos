# Homepage (gethomepage.dev): Next.js, widgets, YAML config in the flake.
{
  lib,
  pkgs,
  ...
}: let
  domain = "homepage.marcpartensky.com";
  appPort = 8612;
  port = 8672;
in {
  services.homepage-dashboard = {
    enable = true;
    listenPort = appPort;
    allowedHosts = "*";
    settings = {
      title = "Homelab";
      description = "tower, self-hosted services";
      theme = "dark";
      color = "slate";
      statusStyle = "dot";
      hideVersion = true;
      layout = {
        "Media" = { style = "row"; columns = 4; };
        "Files" = { style = "row"; columns = 4; };
        "Agent" = { style = "row"; columns = 4; };
        "Development" = { style = "row"; columns = 4; };
        "Remote desktops" = { style = "row"; columns = 4; };
        "System" = { style = "row"; columns = 4; };
      };
    };
    widgets = [
      {
        search = {
          provider = "duckduckgo";
          target = "_blank";
        };
      }
      {
        glances = {
          url = "http://127.0.0.1:61208";
          version = 4;
          cpu = true;
          mem = true;
          cputemp = true;
          uptime = true;
          disk = "/";
        };
      }
    ];
    services = [
      {
        "Media" = [
          {
            "Jellyfin" = {
              href = "https://jellyfin.marcpartensky.com";
              description = "Movies and series";
              icon = "jellyfin.png";
            };
          }
          {
            "Audiobookshelf" = {
              href = "https://audiobookshelf.marcpartensky.com";
              description = "Audiobooks";
              icon = "audiobookshelf.png";
            };
          }
          {
            "Sonarr" = {
              href = "https://sonarr.marcpartensky.com";
              description = "Series";
              icon = "sonarr.png";
            };
          }
          {
            "Radarr" = {
              href = "https://radarr.marcpartensky.com";
              description = "Movies";
              icon = "radarr.png";
            };
          }
          {
            "qBittorrent" = {
              href = "https://torrent.marcpartensky.com";
              description = "Downloads";
              icon = "qbittorrent.png";
            };
          }
          {
            "Navidrome" = {
              href = "https://navidrome.marcpartensky.com";
              description = "Music server";
              icon = "navidrome.png";
            };
          }

          {
            "Aonsoku" = {
              href = "https://music.marcpartensky.com";
              description = "Music web client";
              icon = "musicbrainz.png";
            };
          }

        ];
      }
      {
        "Files" = [
          {
            "Nextcloud" = {
              href = "https://cloud.marcpartensky.com";
              description = "Files and calendar";
              icon = "nextcloud.png";
            };
          }
          {
            "Syncthing" = {
              href = "https://syncthing.marcpartensky.com";
              description = "Device sync";
              icon = "syncthing.png";
            };
          }
          {
            "RustFS" = {
              href = "https://rustfs.marcpartensky.com";
              description = "S3 object storage";
              icon = "rustfs.png";
            };
          }
          {
            "MinIO" = {
              href = "https://store.marcpartensky.com";
              description = "Legacy object storage";
              icon = "minio.png";
            };
          }
          {
            "Fichier" = {
              href = "https://fichier.marcpartensky.com";
              description = "File sharing";
              icon = "filebrowser.png";
            };
          }
          {
            "Droplify" = {
              href = "https://drop.marcpartensky.com";
              description = "File drop";
              icon = "dropbox.png";
            };
          }
          {
            "Shlink" = {
              href = "https://s.marcpartensky.com";
              description = "Short links and sharing";
              icon = "shlink.png";
            };
          }

          {
            "Shlink admin" = {
              href = "https://shlink.marcpartensky.com";
              description = "Links console";
              icon = "shlink.png";
            };
          }

        ];
      }
      {
        "Agent" = [
          {
            "Hermes" = {
              href = "https://hermes.marcpartensky.com";
              description = "Web interface";
              icon = "open-webui.png";
            };
          }
          {
            "Terminal" = {
              href = "https://terminal.marcpartensky.com";
              description = "Hermes terminal";
              icon = "terminal.png";
            };
          }
          {
            "Dashboard Hermes" = {
              href = "https://dash.marcpartensky.com";
              description = "Admin panel";
              icon = "open-webui.png";
            };
          }
          {
            "Hermes Mobile" = {
              href = "https://hermes-mobile.marcpartensky.com";
              description = "Pocket";
              icon = "android.png";
            };
          }
          {
            "Hermes Anna" = {
              href = "https://hermes-anna.marcpartensky.com";
              description = "Guest";
              icon = "chatgpt.png";
            };
          }
          {
            "Hermes Yves" = {
              href = "https://hermes-yves.marcpartensky.com";
              description = "Guest";
              icon = "chatgpt.png";
            };
          }
          {
            "Open Notebook" = {
              href = "https://notebook.marcpartensky.com";
              description = "AI notebooks";
              icon = "jupyter.png";
            };
          }
          {
            "n8n" = {
              href = "https://n8n.marcpartensky.com";
              description = "Automations";
              icon = "n8n.png";
            };
          }
          {
            "Matrix" = {
              href = "https://matrix.marcpartensky.com";
              description = "Messaging";
              icon = "matrix.png";
            };
          }
          {
            "Usage LLM" = {
              href = "https://usage.marcpartensky.com";
              description = "OpenRouter costs";
              icon = "si-openrouter";
            };
          }

        ];
      }
      {
        "Development" = [
          {
            "Gitea" = {
              href = "https://git.marcpartensky.com";
              description = "Git forge";
              icon = "gitea.png";
            };
          }
          {
            "JupyterHub" = {
              href = "https://lab.marcpartensky.com";
              description = "Notebooks";
              icon = "jupyter.png";
            };
          }
          {
            "Taskq" = {
              href = "https://taskq.marcpartensky.com";
              description = "Task queue";
              icon = "link.png";
            };
          }
          {
            "Winnie" = {
              href = "https://winnie.marcpartensky.com";
              description = "Application";
              icon = "link.png";
            };
          }
          {
            "Winnie dev" = {
              href = "https://dev.winnie.marcpartensky.com";
              description = "Vite HMR";
              icon = "vite.png";
            };
          }
          {
            "Winnie API" = {
              href = "https://api.winnie.marcpartensky.com";
              description = "Backend";
              icon = "fastapi.png";
            };
          }
          {
            "RentScout" = {
              href = "https://rentscout.marcpartensky.com";
              description = "Rental listings";
              icon = "link.png";
            };
          }
          {
            "Backtest" = {
              href = "https://backtest.marcpartensky.com";
              description = "Stock backtest";
              icon = "chart.png";
            };
          }
          {
            "Option Pricer" = {
              href = "https://option-pricer.marcpartensky.com";
              description = "Option pricing";
              icon = "chart.png";
            };
          }
          {
            "Portfolio Optimizer" = {
              href = "https://portfolio-optimizer.marcpartensky.com";
              description = "Optimization";
              icon = "chart.png";
            };
          }
          {
            "CV" = {
              href = "https://cv.marcpartensky.com";
              description = "Reactive Resume";
              icon = "reactive-resume.png";
            };
          }
          {
            "Windmill" = {
              href = "https://windmill.marcpartensky.com";
              description = "Jobs and scripts";
              icon = "windmill.png";
            };
          }

        ];
      }
      {
        "Remote desktops" = [
          {
            "Kasm" = {
              href = "https://kasm.marcpartensky.com";
              description = "Remote desktop";
              icon = "kasm.png";
            };
          }
          {
            "Android" = {
              href = "https://android.marcpartensky.com";
              description = "Waydroid";
              icon = "android.png";
            };
          }
          {
            "VNC" = {
              href = "https://vnc.marcpartensky.com";
              description = "niri session";
              icon = "vnc.png";
            };
          }
          {
            "Guacamole" = {
              href = "https://guac.marcpartensky.com";
              description = "Web remote desktop";
              icon = "guacamole.png";
            };
          }
        ];
      }
      {
        "System" = [
          {
            "Glances" = {
              href = "https://proc.marcpartensky.com";
              description = "Host metrics";
              icon = "glances.png";
            };
          }
          {
            "Zitadel" = {
              href = "https://auth.marcpartensky.com";
              description = "SSO";
              icon = "zitadel.png";
            };
          }
          {
            "Pangolin" = {
              href = "https://pangolin.marcpartensky.com";
              description = "Network tunnel";
              icon = "pangolin.png";
            };
          }
          {
            "Traefik" = {
              href = "https://traefik.marcpartensky.com";
              description = "Proxy VPS";
              icon = "traefik.png";
            };
          }
          {
            "Headscale" = {
              href = "https://ts.marcpartensky.com";
              description = "Mesh WireGuard";
              icon = "tailscale.png";
            };
          }
          {
            "Gotify" = {
              href = "https://gotify.marcpartensky.com";
              description = "Notifications";
              icon = "gotify.png";
            };
          }
          {
            "Anki" = {
              href = "https://anki.marcpartensky.com";
              description = "Card sync";
              icon = "anki.png";
            };
          }
          {
            "Vaultwarden" = {
              href = "https://vault.marcpartensky.com";
              description = "Passwords";
              icon = "vaultwarden.png";
            };
          }
          {
            "Stalwart" = {
              href = "https://mail.marcpartensky.com";
              description = "Mail";
              icon = "mailcow.png";
            };
          }
          {
            "Kanidm" = {
              href = "https://idm.vps.marcpartensky.com";
              description = "VPS directory";
              icon = "keycloak.png";
            };
          }
          {
            "Legal" = {
              href = "https://legal.marcpartensky.com";
              description = "Legal pages";
              icon = "link.png";
            };
          }
          {
            "Mesh" = {
              href = "https://mesh.marcpartensky.com";
              description = "Tailnet nodes";
              icon = "tailscale.png";
            };
          }

        ];
      }
    ];
  };

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
