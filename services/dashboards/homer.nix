# Homer: static dashboard, no backend. nginx serves the loopback,
# newt relays from the Pangolin resource homer.marcpartensky.com.
{
  lib,
  pkgs,
  ...
}: let
  domain = "homer.marcpartensky.com";
  port = 8671;
  # Catppuccin Mocha, lavender accent (marc's reference theme).
  ctp = {
    crust = "#11111b";
    mantle = "#181825";
    base = "#1e1e2e";
    surface0 = "#313244";
    overlay0 = "#6c7086";
    subtext0 = "#a6adc8";
    text = "#cdd6f4";
    lavender = "#b4befe";
    mauve = "#cba6f7";
    blue = "#89b4fa";
  };
  colors = {
    highlight-primary = ctp.lavender;
    highlight-secondary = ctp.mauve;
    highlight-hover = ctp.blue;
    background = ctp.base;
    card-background = ctp.mantle;
    text = ctp.text;
    text-header = ctp.base;
    text-title = ctp.text;
    text-subtitle = ctp.subtext0;
    card-shadow = "0 4px 14px 0 rgba(17, 17, 27, 0.65)";
    link = ctp.lavender;
    link-hover = ctp.text;
    footer-background = ctp.crust;
    footer-text = ctp.overlay0;
  };
  settings = {
    title = "Homelab";
    subtitle = "tower";
    documentTitle = "Homelab · tower";
    logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/nixos.png";
    header = true;
    footer = false;
    columns = "4";
    connectivityCheck = false;
    defaults = {
      layout = "columns";
      colorTheme = "dark";
    };
    theme = "default";
    colors = {
      dark = colors;
      light = colors;
    };
    services = [
      {
        name = "Media";
        icon = "fas fa-film";
        items = [
          {
            name = "Jellyfin";
            subtitle = "Movies and series";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jellyfin.png";
            url = "https://jellyfin.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Audiobookshelf";
            subtitle = "Audiobooks";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/audiobookshelf.png";
            url = "https://audiobookshelf.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Sonarr";
            subtitle = "Series";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/sonarr.png";
            url = "https://sonarr.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Radarr";
            subtitle = "Movies";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/radarr.png";
            url = "https://radarr.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "qBittorrent";
            subtitle = "Downloads";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/qbittorrent.png";
            url = "https://torrent.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Navidrome";
            subtitle = "Music server";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/navidrome.png";
            url = "https://navidrome.marcpartensky.com";
            target = "_blank";
          }

          {
            name = "Aonsoku";
            subtitle = "Music web client";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/musicbrainz.png";
            url = "https://music.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Files";
        icon = "fas fa-folder";
        items = [
          {
            name = "Nextcloud";
            subtitle = "Files and calendar";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/nextcloud.png";
            url = "https://cloud.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Syncthing";
            subtitle = "Device sync";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/syncthing.png";
            url = "https://syncthing.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "RustFS";
            subtitle = "S3 object storage";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/rustfs.png";
            url = "https://rustfs.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "MinIO";
            subtitle = "Legacy object storage";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/minio.png";
            url = "https://store.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Fichier";
            subtitle = "File sharing";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/filebrowser.png";
            url = "https://fichier.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Droplify";
            subtitle = "File drop";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/dropbox.png";
            url = "https://drop.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Shlink";
            subtitle = "Short links and sharing";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/shlink.png";
            url = "https://s.marcpartensky.com";
            target = "_blank";
          }

          {
            name = "Shlink admin";
            subtitle = "Links console";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/shlink.png";
            url = "https://shlink.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Agent";
        icon = "fas fa-robot";
        items = [
          {
            name = "Hermes";
            subtitle = "Web interface";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/open-webui.png";
            url = "https://hermes.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Terminal";
            subtitle = "Hermes terminal";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/terminal.png";
            url = "https://terminal.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Dashboard Hermes";
            subtitle = "Admin panel";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/open-webui.png";
            url = "https://dash.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Hermes Mobile";
            subtitle = "Pocket";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/android.png";
            url = "https://hermes-mobile.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Hermes Anna";
            subtitle = "Guest";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/chatgpt.png";
            url = "https://hermes-anna.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Hermes Yves";
            subtitle = "Guest";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/chatgpt.png";
            url = "https://hermes-yves.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Open Notebook";
            subtitle = "AI notebooks";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jupyter.png";
            url = "https://notebook.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "n8n";
            subtitle = "Automations";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/n8n.png";
            url = "https://n8n.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Matrix";
            subtitle = "Messaging";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/matrix.png";
            url = "https://matrix.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Usage LLM";
            subtitle = "OpenRouter costs";
            logo = "https://cdn.simpleicons.org/openrouter";
            url = "https://usage.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Development";
        icon = "fas fa-code";
        items = [
          {
            name = "Gitea";
            subtitle = "Git forge";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/gitea.png";
            url = "https://git.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "JupyterHub";
            subtitle = "Notebooks";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jupyter.png";
            url = "https://lab.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Taskq";
            subtitle = "Task queue";
            logo = "https://cdn.simpleicons.org/task";
            url = "https://taskq.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Winnie";
            subtitle = "Application";
            logo = "https://cdn.simpleicons.org/vite";
            url = "https://winnie.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Winnie dev";
            subtitle = "Vite HMR";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/vite.png";
            url = "https://dev.winnie.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Winnie API";
            subtitle = "Backend";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/fastapi.png";
            url = "https://api.winnie.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "RentScout";
            subtitle = "Rental listings";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/home-assistant.png";
            url = "https://rentscout.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Backtest";
            subtitle = "Stock backtest";
            logo = "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/chartbrew.svg";
            url = "https://backtest.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Option Pricer";
            subtitle = "Option pricing";
            logo = "https://cdn.simpleicons.org/chartdotjs";
            url = "https://option-pricer.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Portfolio Optimizer";
            subtitle = "Optimization";
            logo = "https://cdn.jsdelivr.net/gh/PapirusDevelopmentTeam/papirus_icons/src/apps_star_chart.svg";
            url = "https://portfolio-optimizer.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "CV";
            subtitle = "Reactive Resume";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/reactive-resume.png";
            url = "https://cv.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Windmill";
            subtitle = "Jobs and scripts";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/windmill.png";
            url = "https://windmill.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Remote desktops";
        icon = "fas fa-desktop";
        items = [
          {
            name = "Kasm";
            subtitle = "Remote desktop";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/kasm.png";
            url = "https://kasm.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Android";
            subtitle = "Waydroid";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/android.png";
            url = "https://android.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "VNC";
            subtitle = "niri session";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/novnc.png";
            url = "https://vnc.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Guacamole";
            subtitle = "Web remote desktop";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/guacamole.png";
            url = "https://guac.marcpartensky.com";
            target = "_blank";
          }
        ];
      }
      {
        name = "System";
        icon = "fas fa-server";
        items = [
          {
            name = "Glances";
            subtitle = "Host metrics";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/glances.png";
            url = "https://proc.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Zitadel";
            subtitle = "SSO";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/zitadel.png";
            url = "https://auth.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Pangolin";
            subtitle = "Network tunnel";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/pangolin.png";
            url = "https://pangolin.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Traefik";
            subtitle = "Proxy VPS";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/traefik.png";
            url = "https://traefik.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Headscale";
            subtitle = "Mesh WireGuard";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/tailscale.png";
            url = "https://ts.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Gotify";
            subtitle = "Notifications";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/gotify.png";
            url = "https://gotify.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Anki";
            subtitle = "Card sync";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/anki.png";
            url = "https://anki.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Vaultwarden";
            subtitle = "Passwords";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/vaultwarden.png";
            url = "https://vault.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Stalwart";
            subtitle = "Mail";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/mailcow.png";
            url = "https://mail.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Kanidm";
            subtitle = "VPS directory";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/keycloak.png";
            url = "https://idm.vps.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Legal";
            subtitle = "Legal pages";
            logo = "https://cdn.simpleicons.org/linktree";
            url = "https://legal.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Mesh";
            subtitle = "Tailnet nodes";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/tailscale.png";
            url = "https://mesh.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
    ];
  };
  configFile = (pkgs.formats.yaml { }).generate "homer-config.yml" settings;
in {
  services.nginx.virtualHosts."${domain}" = {
    listen = [{
      addr = "127.0.0.1";
      port = port;
    }];
    serverName = domain;
    root = pkgs.runCommand "homer-homelab" { } ''
      mkdir -p $out
      cp -r ${pkgs.homer}/. $out/
      chmod -R u+w $out
      # Homer reads assets/config.yml (not /config.yml): it is the path
      # it fetches on load, otherwise it shows "No configuration found".
      cp ${configFile} $out/assets/config.yml
    '';
  };
}
