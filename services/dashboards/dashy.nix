# Dashy: static build via the nixpkgs module (dashy-ui), config compiled
# into the store. No Node server, so zero RAM at rest.
{
  lib,
  pkgs,
  ...
}: let
  domain = "dashy.marcpartensky.com";
  port = 8674;
in {
  services.dashy = {
    enable = true;
    virtualHost = {
      enableNginx = true;
      inherit domain;
    };
    settings = {
      pageInfo = {
        title = "Homelab";
        description = "tower";
        navLinks = [];
        footerText = "";
        showTitle = false;
        hideFooter = true;
      };
      appConfig = {
        theme = "minimal";
        layout = "auto";
        iconSize = "medium";
        statusCheck = false;
        hideSettings = true;
        enableFontAwesome = false;
        language = "fr";
      };
      sections = [
      {
        name = "Media";
        icon = "fas fa-film";
        displayData = { cols = 4; };
        items = [
          {
            title = "Jellyfin";
            description = "Movies and series";
            url = "https://jellyfin.marcpartensky.com";
            icon = "jellyfin";
            target = "newtab";
          }
          {
            title = "Audiobookshelf";
            description = "Audiobooks";
            url = "https://audiobookshelf.marcpartensky.com";
            icon = "audiobookshelf";
            target = "newtab";
          }
          {
            title = "Sonarr";
            description = "Series";
            url = "https://sonarr.marcpartensky.com";
            icon = "sonarr";
            target = "newtab";
          }
          {
            title = "Radarr";
            description = "Films";
            url = "https://radarr.marcpartensky.com";
            icon = "radarr";
            target = "newtab";
          }
          {
            title = "qBittorrent";
            description = "Downloads";
            url = "https://torrent.marcpartensky.com";
            icon = "qbittorrent";
            target = "newtab";
          }
        ];
      }
      {
        name = "Files";
        icon = "fas fa-folder";
        displayData = { cols = 4; };
        items = [
          {
            title = "Nextcloud";
            description = "Files and calendar";
            url = "https://cloud.marcpartensky.com";
            icon = "nextcloud";
            target = "newtab";
          }
          {
            title = "Syncthing";
            description = "Device sync";
            url = "https://syncthing.marcpartensky.com";
            icon = "syncthing";
            target = "newtab";
          }
          {
            title = "RustFS";
            description = "S3 object storage";
            url = "https://rustfs.marcpartensky.com";
            icon = "rustfs";
            target = "newtab";
          }
          {
            title = "MinIO";
            description = "Legacy object storage";
            url = "https://store.marcpartensky.com";
            icon = "minio";
            target = "newtab";
          }
          {
            title = "File";
            description = "File sharing";
            url = "https://fichier.marcpartensky.com";
            icon = "filebrowser";
            target = "newtab";
          }
          {
            title = "Droplify";
            description = "File drop";
            url = "https://drop.marcpartensky.com";
            icon = "dropbox";
            target = "newtab";
          }
        ];
      }
      {
        name = "Agent";
        icon = "fas fa-robot";
        displayData = { cols = 4; };
        items = [
          {
            title = "Hermes";
            description = "Web interface";
            url = "https://hermes.marcpartensky.com";
            icon = "open-webui";
            target = "newtab";
          }
          {
            title = "Terminal";
            description = "Terminal Hermes";
            url = "https://terminal.marcpartensky.com";
            icon = "terminal";
            target = "newtab";
          }
          {
            title = "Hermes Mobile";
            description = "Pocket";
            url = "https://hermes-mobile.marcpartensky.com";
            icon = "android";
            target = "newtab";
          }
          {
            title = "Hermes Anna";
            description = "Guest";
            url = "https://hermes-anna.marcpartensky.com";
            icon = "chatgpt";
            target = "newtab";
          }
          {
            title = "Hermes Yves";
            description = "Guest";
            url = "https://hermes-yves.marcpartensky.com";
            icon = "chatgpt";
            target = "newtab";
          }
          {
            title = "Open Notebook";
            description = "AI notebooks";
            url = "https://notebook.marcpartensky.com";
            icon = "jupyter";
            target = "newtab";
          }
          {
            title = "n8n";
            description = "Automations";
            url = "https://n8n.marcpartensky.com";
            icon = "n8n";
            target = "newtab";
          }
          {
            title = "Matrix";
            description = "Messaging";
            url = "https://matrix.marcpartensky.com";
            icon = "matrix";
            target = "newtab";
          }
        ];
      }
      {
        name = "Development";
        icon = "fas fa-code";
        displayData = { cols = 4; };
        items = [
          {
            title = "Gitea";
            description = "Git forge";
            url = "https://git.marcpartensky.com";
            icon = "gitea";
            target = "newtab";
          }
          {
            title = "JupyterHub";
            description = "Notebooks";
            url = "https://lab.marcpartensky.com";
            icon = "jupyter";
            target = "newtab";
          }
          {
            title = "Taskq";
            description = "Task queue";
            url = "https://taskq.marcpartensky.com";
            icon = "link";
            target = "newtab";
          }
          {
            title = "Winnie";
            description = "Application";
            url = "https://winnie.marcpartensky.com";
            icon = "link";
            target = "newtab";
          }
          {
            title = "Winnie dev";
            description = "Vite HMR";
            url = "https://dev.winnie.marcpartensky.com";
            icon = "vite";
            target = "newtab";
          }
          {
            title = "Winnie API";
            description = "Backend";
            url = "https://api.winnie.marcpartensky.com";
            icon = "fastapi";
            target = "newtab";
          }
          {
            title = "RentScout";
            description = "Rental listings";
            url = "https://rentscout.marcpartensky.com";
            icon = "link";
            target = "newtab";
          }
          {
            title = "Backtest";
            description = "Stock market backtest";
            url = "https://backtest.marcpartensky.com";
            icon = "chart";
            target = "newtab";
          }
          {
            title = "Option Pricer";
            description = "Option pricing";
            url = "https://option-pricer.marcpartensky.com";
            icon = "chart";
            target = "newtab";
          }
          {
            title = "Portfolio Optimizer";
            description = "Optimization";
            url = "https://portfolio-optimizer.marcpartensky.com";
            icon = "chart";
            target = "newtab";
          }
          {
            title = "CV";
            description = "Reactive Resume";
            url = "https://cv.marcpartensky.com";
            icon = "reactive-resume";
            target = "newtab";
          }
        ];
      }
      {
        name = "Remote desktops";
        icon = "fas fa-desktop";
        displayData = { cols = 4; };
        items = [
          {
            title = "Kasm";
            description = "Remote desktop";
            url = "https://kasm.marcpartensky.com";
            icon = "kasm";
            target = "newtab";
          }
          {
            title = "Android";
            description = "Waydroid";
            url = "https://android.marcpartensky.com";
            icon = "android";
            target = "newtab";
          }
          {
            title = "VNC";
            description = "Session niri";
            url = "https://vnc.marcpartensky.com";
            icon = "vnc";
            target = "newtab";
          }
          {
            title = "Guacamole";
            description = "Web meeting";
            url = "https://guac.marcpartensky.com";
            icon = "guacamole";
            target = "newtab";
          }
        ];
      }
      {
        name = "System";
        icon = "fas fa-server";
        displayData = { cols = 4; };
        items = [
          {
            title = "Glances";
            description = "Host metrics";
            url = "https://proc.marcpartensky.com";
            icon = "glances";
            target = "newtab";
          }
          {
            title = "Zitadel";
            description = "SSO";
            url = "https://auth.marcpartensky.com";
            icon = "zitadel";
            target = "newtab";
          }
          {
            title = "Pangolin";
            description = "Network tunnel";
            url = "https://pangolin.marcpartensky.com";
            icon = "pangolin";
            target = "newtab";
          }
          {
            title = "Traefik";
            description = "Proxy VPS";
            url = "https://traefik.marcpartensky.com";
            icon = "traefik";
            target = "newtab";
          }
          {
            title = "Headscale";
            description = "Mesh WireGuard";
            url = "https://ts.marcpartensky.com";
            icon = "tailscale";
            target = "newtab";
          }
          {
            title = "Gotify";
            description = "Notifications";
            url = "https://gotify.marcpartensky.com";
            icon = "gotify";
            target = "newtab";
          }
          {
            title = "Anki";
            description = "Card sync";
            url = "https://anki.marcpartensky.com";
            icon = "anki";
            target = "newtab";
          }
          {
            title = "Vaultwarden";
            description = "Passwords";
            url = "https://vault.marcpartensky.com";
            icon = "vaultwarden";
            target = "newtab";
          }
          {
            title = "Stalwart";
            description = "Mail";
            url = "https://mail.marcpartensky.com";
            icon = "mailcow";
            target = "newtab";
          }
          {
            title = "Kanidm";
            description = "VPS directory";
            url = "https://idm.vps.marcpartensky.com";
            icon = "keycloak";
            target = "newtab";
          }
          {
            title = "Legal";
            description = "Legal pages";
            url = "https://legal.marcpartensky.com";
            icon = "link";
            target = "newtab";
          }
        ];
      }
      ];
    };
  };

  services.nginx.virtualHosts."${domain}".listen = [{
    addr = "127.0.0.1";
    port = port;
  }];
}
