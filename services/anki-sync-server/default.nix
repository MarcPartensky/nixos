# services/anki-sync-server/default.nix
# Serveur de synchronisation Anki auto-hébergé, implémentation OFFICIELLE en
# Rust : le paquet nixpkgs `anki-sync-server` compile uniquement le binaire
# standalone depuis le repo ankitects/anki (même version que le desktop Anki,
# 25.09.4 dans la nixpkgs épinglée). Zéro Python.
#
# Le serveur écoute en loopback (127.0.0.1:27701) et ne sert AUCUNE page web
# (404 vide sur /, ce qui veut dire « rien » dans un navigateur). Une façade
# nginx en loopback (127.0.0.1:27702) sert une page de statut sur / et proxifie
# les routes de sync (/sync/*, /msync/*, /health) vers 27701. Le blueprint
# Pangolin/newt expose la façade sur anki.marcpartensky.com.
# PAS de SSO Pangolin : les clients Anki (desktop, AnkiMobile, AnkiDroid) ne
# savent pas suivre une redirection navigateur ; l'authentification repose sur
# le couple utilisateur/mot de passe du serveur Anki lui-même (SYNC_USER),
# transmis en HTTPS par le reverse proxy.
#
# Mot de passe du compte "marc" dans secrets/anki.yml (sops). Le module nixpkgs
# lit passwordFile via LoadCredential systemd (jamais en clair dans le store).
{
  config,
  lib,
  pkgs,
  ...
}: let
  syncPort = 27701; # port du serveur Anki (loopback)
  proxyPort = 27702; # port de la façade nginx (loopback)
  statusPage = pkgs.stdenv.mkDerivation {
    pname = "anki-sync-status";
    version = "1";
    src = pkgs.writeTextFile {
      name = "anki-sync-status.html";
      text = ''
        <!doctype html>
        <html lang='fr'>
        <head>
        <meta charset='utf-8'>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <title>Anki Sync Server</title>
        <style>
        body{background:#1e1e2e;color:#cdd6f4;font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center}
        .card{background:#181825;border:1px solid #585b70;border-radius:12px;padding:2rem 2.5rem;max-width:34rem}
        h1{color:#ffffff;font-size:1.35rem;margin:0 0 .6rem}
        .badge{display:inline-block;background:#2a2a3d;color:#b4befe;border:1px solid #b4befe;border-radius:999px;padding:.15rem .6rem;font-size:.75rem;margin-bottom:1rem}
        p{color:#a6adc8;line-height:1.55;font-size:.95rem;margin:.6rem 0}
        code{background:#2a2a3d;color:#f1cae1;padding:.05rem .35rem;border-radius:4px;font-size:.85rem}
        </style>
        </head>
        <body>
        <div class='card'>
        <h1>Anki Sync Server</h1>
        <span class='badge'>en ligne</span>
        <p>Ce domaine expose uniquement l'API de synchronisation Anki pour les clients de bureau et mobiles. Il n'y a pas d'interface web à afficher ici.</p>
        <p>Dans Anki (préférences, onglet <code>synchronisation</code>), renseignez <code>https://anki.marcpartensky.com</code> comme serveur de sync.</p>
        <p>Santé du service : <code>GET /health</code></p>
        </div>
        </body>
        </html>
      '';
    };
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp $src $out/index.html
    '';
    meta.description = "Page de statut du serveur de sync Anki";
  };
in {
  sops.secrets."anki-sync-server/password" = {
    key = "password";
    sopsFile = ../../secrets/anki.yml;
  };

  services.anki-sync-server = {
    enable = true;
    address = "127.0.0.1";
    # port par défaut : 27701
    users = [
      {
        username = "marc";
        passwordFile = config.sops.secrets."anki-sync-server/password".path;
      }
    ];
  };

  # Façade nginx, loopback uniquement : page de statut sur / (le serveur Anki
  # n'a pas d'UI), proxy des routes de sync vers 27701. Timeouts longs (grosses
  # collections), pas de limite de taille de corps (uploads de médias : images,
  # vidéos).
  services.nginx.virtualHosts."anki-sync-status" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    extraConfig = "client_max_body_size 0;";
    locations = {
      "/sync" = {
        proxyPass = "http://127.0.0.1:${toString syncPort}";
        extraConfig = ''
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        '';
      };
      "/msync" = {
        proxyPass = "http://127.0.0.1:${toString syncPort}";
        extraConfig = ''
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        '';
      };
      "/health" = {
        proxyPass = "http://127.0.0.1:${toString syncPort}";
      };
      "/" = {
        root = statusPage;
      };
    };
  };

  # Ressource publique Pangolin (newt, site "tower") : anki.marcpartensky.com
  # -> 127.0.0.1:27702 (façade nginx). Cle `proxy-resources` + champ
  # `protocol` = schema réellement compris par le Pangolin du VPS (cf.
  # services/newt). Pas d'auth Pangolin (clients natifs). Pas de healthcheck
  # déclaré : la façade répond 200 sur /, donc le check par défaut passe.
  services.newt.blueprint.proxy-resources."anki-sync-server" = {
    name = "anki-sync-server";
    protocol = "http";
    full-domain = "anki.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = proxyPort;
        method = "http";
      }
    ];
  };

  # Garde-fou : les ports locaux ne doivent jamais être ouverts au
  # firewall/LAN.
  assertions = [
    {
      assertion = !(lib.elem syncPort config.networking.firewall.allowedTCPPorts)
        && !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "anki-sync-server : les ports locaux ne doivent pas être ouverts au firewall (exposition uniquement via Pangolin/newt).";
    }
  ];
}