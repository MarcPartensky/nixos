# Homer : dashboard statique, aucun backend. nginx sert la boucle locale,
# newt relaie depuis la ressource Pangolin homer.marcpartensky.com.
{
  lib,
  pkgs,
  ...
}: let
  domain = "homer.marcpartensky.com";
  port = 8671;
  # Catppuccin Mocha, accent lavender (theme de reference de marc).
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
        name = "Média";
        icon = "fas fa-film";
        items = [
          {
            name = "Jellyfin";
            subtitle = "Films et séries";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jellyfin.png";
            url = "https://jellyfin.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Audiobookshelf";
            subtitle = "Livres audio";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/audiobookshelf.png";
            url = "https://audiobookshelf.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Sonarr";
            subtitle = "Séries";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/sonarr.png";
            url = "https://sonarr.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Radarr";
            subtitle = "Films";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/radarr.png";
            url = "https://radarr.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "qBittorrent";
            subtitle = "Téléchargements";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/qbittorrent.png";
            url = "https://torrent.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Navidrome";
            subtitle = "Serveur musical";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/navidrome.png";
            url = "https://navidrome.marcpartensky.com";
            target = "_blank";
          }

          {
            name = "Aonsoku";
            subtitle = "Client web musical";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/musicbrainz.png";
            url = "https://music.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Fichiers";
        icon = "fas fa-folder";
        items = [
          {
            name = "Nextcloud";
            subtitle = "Fichiers et calendrier";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/nextcloud.png";
            url = "https://cloud.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Syncthing";
            subtitle = "Synchro appareils";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/syncthing.png";
            url = "https://syncthing.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "RustFS";
            subtitle = "Stockage objet S3";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/rustfs.png";
            url = "https://rustfs.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "MinIO";
            subtitle = "Stockage objet hérité";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/minio.png";
            url = "https://store.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Fichier";
            subtitle = "Partage de fichiers";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/filebrowser.png";
            url = "https://fichier.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Droplify";
            subtitle = "Dépôt de fichiers";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/dropbox.png";
            url = "https://drop.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Shlink";
            subtitle = "Liens courts et partage";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/shlink.png";
            url = "https://s.marcpartensky.com";
            target = "_blank";
          }

          {
            name = "Shlink admin";
            subtitle = "Console des liens";
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
            subtitle = "Interface web";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/open-webui.png";
            url = "https://hermes.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Terminal";
            subtitle = "Terminal Hermes";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/terminal.png";
            url = "https://terminal.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Dashboard Hermes";
            subtitle = "Panneau d'admin";
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
            subtitle = "Invitée";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/chatgpt.png";
            url = "https://hermes-anna.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Hermes Yves";
            subtitle = "Invité";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/chatgpt.png";
            url = "https://hermes-yves.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Open Notebook";
            subtitle = "Notebooks IA";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jupyter.png";
            url = "https://notebook.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "n8n";
            subtitle = "Automatisations";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/n8n.png";
            url = "https://n8n.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Matrix";
            subtitle = "Messagerie";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/matrix.png";
            url = "https://matrix.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Usage LLM";
            subtitle = "Coûts OpenRouter";
            logo = "https://cdn.simpleicons.org/openrouter";
            url = "https://usage.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Développement";
        icon = "fas fa-code";
        items = [
          {
            name = "Gitea";
            subtitle = "Forge git";
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
            subtitle = "File de tâches";
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
            subtitle = "Annonces de location";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/home-assistant.png";
            url = "https://rentscout.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Backtest";
            subtitle = "Backtest boursier";
            logo = "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/chartbrew.svg";
            url = "https://backtest.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Option Pricer";
            subtitle = "Pricing d'options";
            logo = "https://cdn.simpleicons.org/chartdotjs";
            url = "https://option-pricer.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Portfolio Optimizer";
            subtitle = "Optimisation";
            logo = "https://cdn.jsdelivr.net/gh/PapirusDevelopmentTeam/papirus_icons/src/apps_star_chart.svg";
            url = "https://portfolio-optimizer.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "CV";
            subtitle = "Réactive Resume";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/reactive-resume.png";
            url = "https://cv.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Windmill";
            subtitle = "Jobs et scripts";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/windmill.png";
            url = "https://windmill.marcpartensky.com";
            target = "_blank";
          }

        ];
      }
      {
        name = "Bureaux distants";
        icon = "fas fa-desktop";
        items = [
          {
            name = "Kasm";
            subtitle = "Bureau distant";
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
            subtitle = "Session niri";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/novnc.png";
            url = "https://vnc.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Guacamole";
            subtitle = "RDV web";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/guacamole.png";
            url = "https://guac.marcpartensky.com";
            target = "_blank";
          }
        ];
      }
      {
        name = "Système";
        icon = "fas fa-server";
        items = [
          {
            name = "Glances";
            subtitle = "Métriques hôte";
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
            subtitle = "Tunnel réseau";
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
            subtitle = "Synchro cartes";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/anki.png";
            url = "https://anki.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Vaultwarden";
            subtitle = "Mots de passe";
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
            subtitle = "Annuaire VPS";
            logo = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/keycloak.png";
            url = "https://idm.vps.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Legal";
            subtitle = "Pages légales";
            logo = "https://cdn.simpleicons.org/linktree";
            url = "https://legal.marcpartensky.com";
            target = "_blank";
          }
          {
            name = "Mesh";
            subtitle = "Nœuds du tailnet";
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
      # Homer lit assets/config.yml (et non /config.yml) : c'est le chemin
      # qu'il fetche au chargement, sinon il affiche "No configuration found".
      cp ${configFile} $out/assets/config.yml
    '';
  };
}
