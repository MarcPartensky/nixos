# services/anki-sync-server/default.nix
# Self-hosted Anki sync server, OFFICIAL Rust implementation: the nixpkgs
# package `anki-sync-server` compiles only the standalone binary from the
# ankitects/anki repo (same version as the Anki desktop,
# 25.09.4 in the pinned nixpkgs). Zero Python.
#
# The server listens on loopback (127.0.0.1:27701) and serves NO web page
# (empty 404 on /, which means "nothing" in a browser). An nginx front
# on loopback (127.0.0.1:27702) serves a status page on / and proxies
# the sync routes (/sync/*, /msync/*, /health) to 27701. The
# Pangolin/newt blueprint exposes the front on anki.marcpartensky.com.
# NO Pangolin SSO: the Anki clients (desktop, AnkiMobile, AnkiDroid) do not
# know how to follow a browser redirect; authentication relies on
# the user/password pair of the Anki server itself (SYNC_USER),
# transmitted over HTTPS by the reverse proxy.
#
# Password of the "marc" account in secrets/anki.yml (sops). The nixpkgs module
# reads passwordFile via systemd LoadCredential (never in clear in the store).
{
  config,
  lib,
  pkgs,
  ...
}: let
  syncPort = 27701; # Anki server port (loopback)
  proxyPort = 27702; # nginx front port (loopback)
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
        <p>This domain only exposes the Anki sync API for desktop and mobile clients. There is no web interface to display here.</p>
        <p>In Anki (preferences, <code>sync</code> tab), enter <code>https://anki.marcpartensky.com</code> as the sync server.</p>
        <p>Service health: <code>GET /health</code></p>
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
    meta.description = "Status page of the Anki sync server";
  };
in {
  sops.secrets."anki-sync-server/password" = {
    key = "password";
    sopsFile = ../../secrets/anki.yml;
  };

  services.anki-sync-server = {
    enable = true;
    address = "127.0.0.1";
    # default port: 27701
    users = [
      {
        username = "marc";
        passwordFile = config.sops.secrets."anki-sync-server/password".path;
      }
    ];
  };

  # nginx front, loopback only: status page on / (the Anki server
  # has no UI), proxy of the sync routes to 27701. Long timeouts (large
  # collections), no body size limit (media uploads: images,
  # videos).
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

  # Public Pangolin resource (newt, "tower" site): anki.marcpartensky.com
  # -> 127.0.0.1:27702 (nginx front). Key `proxy-resources` + field
  # `protocol` = schema actually understood by the VPS's Pangolin (cf.
  # services/newt). No Pangolin auth (native clients).
  # MANDATORY healthcheck on /health: without a healthcheck block, newt checks
  # /healthz by default, which nginx proxies (prefix /health) to the Anki
  # server which answers 404 -> target marked unhealthy -> "no available server"
  # on the domain (experienced on 11/10/2026).
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
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = proxyPort;
          path = "/health";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # Safeguard: the local ports must never be opened at the
  # firewall/LAN.
  assertions = [
    {
      assertion = !(lib.elem syncPort config.networking.firewall.allowedTCPPorts)
        && !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "anki-sync-server: the local ports must not be opened at the firewall (exposure only via Pangolin/newt).";
    }
  ];
}