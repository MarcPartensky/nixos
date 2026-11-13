# Homepage (gethomepage.dev) : Next.js, widgets, config YAML dans le flake.
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
      description = "tower, services auto-hébergés";
      theme = "dark";
      color = "slate";
      statusStyle = "dot";
      hideVersion = true;
      layout = {
        "Média" = { style = "row"; columns = 4; };
        "Fichiers" = { style = "row"; columns = 4; };
        "Agent" = { style = "row"; columns = 4; };
        "Développement" = { style = "row"; columns = 4; };
        "Bureaux distants" = { style = "row"; columns = 4; };
        "Système" = { style = "row"; columns = 4; };
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
        "Média" = [
          {
            "Jellyfin" = {
              href = "https://jellyfin.marcpartensky.com";
              description = "Films et séries";
              icon = "jellyfin.png";
            };
          }
          {
            "Audiobookshelf" = {
              href = "https://audiobookshelf.marcpartensky.com";
              description = "Livres audio";
              icon = "audiobookshelf.png";
            };
          }
          {
            "Sonarr" = {
              href = "https://sonarr.marcpartensky.com";
              description = "Séries";
              icon = "sonarr.png";
            };
          }
          {
            "Radarr" = {
              href = "https://radarr.marcpartensky.com";
              description = "Films";
              icon = "radarr.png";
            };
          }
          {
            "qBittorrent" = {
              href = "https://torrent.marcpartensky.com";
              description = "Téléchargements";
              icon = "qbittorrent.png";
            };
          }
          {
            "Navidrome" = {
              href = "https://navidrome.marcpartensky.com";
              description = "Serveur musical";
              icon = "navidrome.png";
            };
          }

          {
            "Aonsoku" = {
              href = "https://music.marcpartensky.com";
              description = "Client web musical";
              icon = "musicbrainz.png";
            };
          }

        ];
      }
      {
        "Fichiers" = [
          {
            "Nextcloud" = {
              href = "https://cloud.marcpartensky.com";
              description = "Fichiers et calendrier";
              icon = "nextcloud.png";
            };
          }
          {
            "Syncthing" = {
              href = "https://syncthing.marcpartensky.com";
              description = "Synchro appareils";
              icon = "syncthing.png";
            };
          }
          {
            "RustFS" = {
              href = "https://rustfs.marcpartensky.com";
              description = "Stockage objet S3";
              icon = "rustfs.png";
            };
          }
          {
            "MinIO" = {
              href = "https://store.marcpartensky.com";
              description = "Stockage objet hérité";
              icon = "minio.png";
            };
          }
          {
            "Fichier" = {
              href = "https://fichier.marcpartensky.com";
              description = "Partage de fichiers";
              icon = "filebrowser.png";
            };
          }
          {
            "Droplify" = {
              href = "https://drop.marcpartensky.com";
              description = "Dépôt de fichiers";
              icon = "dropbox.png";
            };
          }
          {
            "Shlink" = {
              href = "https://s.marcpartensky.com";
              description = "Liens courts et partage";
              icon = "shlink.png";
            };
          }

          {
            "Shlink admin" = {
              href = "https://shlink.marcpartensky.com";
              description = "Console des liens";
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
              description = "Interface web";
              icon = "open-webui.png";
            };
          }
          {
            "Terminal" = {
              href = "https://terminal.marcpartensky.com";
              description = "Terminal Hermes";
              icon = "terminal.png";
            };
          }
          {
            "Dashboard Hermes" = {
              href = "https://dash.marcpartensky.com";
              description = "Panneau d'admin";
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
              description = "Invitée";
              icon = "chatgpt.png";
            };
          }
          {
            "Hermes Yves" = {
              href = "https://hermes-yves.marcpartensky.com";
              description = "Invité";
              icon = "chatgpt.png";
            };
          }
          {
            "Open Notebook" = {
              href = "https://notebook.marcpartensky.com";
              description = "Notebooks IA";
              icon = "jupyter.png";
            };
          }
          {
            "n8n" = {
              href = "https://n8n.marcpartensky.com";
              description = "Automatisations";
              icon = "n8n.png";
            };
          }
          {
            "Matrix" = {
              href = "https://matrix.marcpartensky.com";
              description = "Messagerie";
              icon = "matrix.png";
            };
          }
          {
            "Usage LLM" = {
              href = "https://usage.marcpartensky.com";
              description = "Coûts OpenRouter";
              icon = "si-openrouter";
            };
          }

        ];
      }
      {
        "Développement" = [
          {
            "Gitea" = {
              href = "https://git.marcpartensky.com";
              description = "Forge git";
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
              description = "File de tâches";
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
              description = "Annonces de location";
              icon = "link.png";
            };
          }
          {
            "Backtest" = {
              href = "https://backtest.marcpartensky.com";
              description = "Backtest boursier";
              icon = "chart.png";
            };
          }
          {
            "Option Pricer" = {
              href = "https://option-pricer.marcpartensky.com";
              description = "Pricing d'options";
              icon = "chart.png";
            };
          }
          {
            "Portfolio Optimizer" = {
              href = "https://portfolio-optimizer.marcpartensky.com";
              description = "Optimisation";
              icon = "chart.png";
            };
          }
          {
            "CV" = {
              href = "https://cv.marcpartensky.com";
              description = "Réactive Resume";
              icon = "reactive-resume.png";
            };
          }
          {
            "Windmill" = {
              href = "https://windmill.marcpartensky.com";
              description = "Jobs et scripts";
              icon = "windmill.png";
            };
          }

        ];
      }
      {
        "Bureaux distants" = [
          {
            "Kasm" = {
              href = "https://kasm.marcpartensky.com";
              description = "Bureau distant";
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
              description = "Session niri";
              icon = "vnc.png";
            };
          }
          {
            "Guacamole" = {
              href = "https://guac.marcpartensky.com";
              description = "RDV web";
              icon = "guacamole.png";
            };
          }
        ];
      }
      {
        "Système" = [
          {
            "Glances" = {
              href = "https://proc.marcpartensky.com";
              description = "Métriques hôte";
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
              description = "Tunnel réseau";
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
              description = "Synchro cartes";
              icon = "anki.png";
            };
          }
          {
            "Vaultwarden" = {
              href = "https://vault.marcpartensky.com";
              description = "Mots de passe";
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
              description = "Annuaire VPS";
              icon = "keycloak.png";
            };
          }
          {
            "Legal" = {
              href = "https://legal.marcpartensky.com";
              description = "Pages légales";
              icon = "link.png";
            };
          }
          {
            "Mesh" = {
              href = "https://mesh.marcpartensky.com";
              description = "Nœuds du tailnet";
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
