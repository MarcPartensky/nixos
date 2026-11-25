# Dashy : build statique via le module nixpkgs (dashy-ui), config compilée
# dans le store. Pas de serveur Node, donc zéro RAM au repos.
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
        name = "Média";
        icon = "fas fa-film";
        displayData = { cols = 4; };
        items = [
          {
            title = "Jellyfin";
            description = "Films et séries";
            url = "https://jellyfin.marcpartensky.com";
            icon = "jellyfin";
            target = "newtab";
          }
          {
            title = "Audiobookshelf";
            description = "Livres audio";
            url = "https://audiobookshelf.marcpartensky.com";
            icon = "audiobookshelf";
            target = "newtab";
          }
          {
            title = "Sonarr";
            description = "Séries";
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
            description = "Téléchargements";
            url = "https://torrent.marcpartensky.com";
            icon = "qbittorrent";
            target = "newtab";
          }
        ];
      }
      {
        name = "Fichiers";
        icon = "fas fa-folder";
        displayData = { cols = 4; };
        items = [
          {
            title = "Nextcloud";
            description = "Fichiers et calendrier";
            url = "https://cloud.marcpartensky.com";
            icon = "nextcloud";
            target = "newtab";
          }
          {
            title = "Syncthing";
            description = "Synchro appareils";
            url = "https://syncthing.marcpartensky.com";
            icon = "syncthing";
            target = "newtab";
          }
          {
            title = "RustFS";
            description = "Stockage objet S3";
            url = "https://rustfs.marcpartensky.com";
            icon = "rustfs";
            target = "newtab";
          }
          {
            title = "MinIO";
            description = "Stockage objet hérité";
            url = "https://store.marcpartensky.com";
            icon = "minio";
            target = "newtab";
          }
          {
            title = "Fichier";
            description = "Partage de fichiers";
            url = "https://fichier.marcpartensky.com";
            icon = "filebrowser";
            target = "newtab";
          }
          {
            title = "Droplify";
            description = "Dépôt de fichiers";
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
            description = "Interface web";
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
            description = "Invitée";
            url = "https://hermes-anna.marcpartensky.com";
            icon = "chatgpt";
            target = "newtab";
          }
          {
            title = "Hermes Yves";
            description = "Invité";
            url = "https://hermes-yves.marcpartensky.com";
            icon = "chatgpt";
            target = "newtab";
          }
          {
            title = "Open Notebook";
            description = "Notebooks IA";
            url = "https://notebook.marcpartensky.com";
            icon = "jupyter";
            target = "newtab";
          }
          {
            title = "n8n";
            description = "Automatisations";
            url = "https://n8n.marcpartensky.com";
            icon = "n8n";
            target = "newtab";
          }
          {
            title = "Matrix";
            description = "Messagerie";
            url = "https://matrix.marcpartensky.com";
            icon = "matrix";
            target = "newtab";
          }
        ];
      }
      {
        name = "Développement";
        icon = "fas fa-code";
        displayData = { cols = 4; };
        items = [
          {
            title = "Gitea";
            description = "Forge git";
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
            description = "File de tâches";
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
            description = "Annonces de location";
            url = "https://rentscout.marcpartensky.com";
            icon = "link";
            target = "newtab";
          }
          {
            title = "Backtest";
            description = "Backtest boursier";
            url = "https://backtest.marcpartensky.com";
            icon = "chart";
            target = "newtab";
          }
          {
            title = "Option Pricer";
            description = "Pricing d'options";
            url = "https://option-pricer.marcpartensky.com";
            icon = "chart";
            target = "newtab";
          }
          {
            title = "Portfolio Optimizer";
            description = "Optimisation";
            url = "https://portfolio-optimizer.marcpartensky.com";
            icon = "chart";
            target = "newtab";
          }
          {
            title = "CV";
            description = "Réactive Resume";
            url = "https://cv.marcpartensky.com";
            icon = "reactive-resume";
            target = "newtab";
          }
        ];
      }
      {
        name = "Bureaux distants";
        icon = "fas fa-desktop";
        displayData = { cols = 4; };
        items = [
          {
            title = "Kasm";
            description = "Bureau distant";
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
            description = "RDV web";
            url = "https://guac.marcpartensky.com";
            icon = "guacamole";
            target = "newtab";
          }
        ];
      }
      {
        name = "Système";
        icon = "fas fa-server";
        displayData = { cols = 4; };
        items = [
          {
            title = "Glances";
            description = "Métriques hôte";
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
            description = "Tunnel réseau";
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
            description = "Synchro cartes";
            url = "https://anki.marcpartensky.com";
            icon = "anki";
            target = "newtab";
          }
          {
            title = "Vaultwarden";
            description = "Mots de passe";
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
            description = "Annuaire VPS";
            url = "https://idm.vps.marcpartensky.com";
            icon = "keycloak";
            target = "newtab";
          }
          {
            title = "Legal";
            description = "Pages légales";
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
