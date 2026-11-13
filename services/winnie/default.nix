# services/winnie/default.nix
#
# Activation de Winnie sur tower. La source de verite est le flake du PROJET
# (/home/marc/git/winnie) : son `nixosModules.default` declare l'infrastructure
# (utilisateur/groupe winnie, base PostgreSQL + schema, secret JWT, bucket S3
# Garage) et l'unite du backend. Ce module-ci ne porte que l'activation, les
# secrets sops et les unites qui ne peuvent pas vivre dans le flake projet : le
# front statique (app/dist, construit par npm HORS sandbox), le serveur de dev
# Vite et l'ingest nocturne.
#
# POURQUOI getFlake ET PAS UN INPUT : le flake systeme reste propre (skill
# flake-separation) et l'evaluation impure est deja celle de `nixos-rebuild
# --impure`. Ne JAMAIS retirer l'import ci-dessous sans qu'un autre chemin
# fournisse le meme module : un import retire supprime les unites au switch
# suivant (vecu le 12/11 : module supprime du flake systeme le 10/11, switch du
# 12/11 -> winnie-backend, winnie-frontend et winnie-dev disparus, api et front
# en 502/503).
#
# ECART ASSUME, a retirer quand le working tree sera committe : le package
# `backend` du flake se construit depuis l'arbre GIT, or les modules non
# trackes du working tree (handlers/agent.rs, mcp.rs, api_tokens.rs) n'y sont
# pas, donc ce package ne compile pas. On epingle les binaires compiles par
# cargo dans le repo ; Nix les copie dans le store, ce qui les protege du GC.
# Consequences : un changement Rust n'existe en prod qu'apres `cargo build
# --release` DANS le repo puis un switch. Idem pour le front : `npm run build`
# puis switch (builtins.path est impur, la copie date de l'evaluation).
{
  config,
  pkgs,
  lib,
  ...
}: let
  # `path:` et non `git+file://` : la forme git passe par libgit2, qui refuse un
  # dépôt appartenant à un autre utilisateur ("not owned by current user") — or
  # tout nixos-rebuild tourne sous root via sudo, donc git+file casse chaque
  # switch.
  #
  # COUT MESURE (13/11) : l'arbre winnie fait 16 Go, dont 11,5 Go de `*/target/`,
  # sur 72 570 fichiers. Un `path:` oblige Nix a relire tout ca a CHAQUE
  # evaluation (`nix hash path /home/marc/git/winnie` ne finit pas en 280 s,
  # contre 1,3 s pour le depot nixos qui pese 6 Mo) : c'est la cause premiere
  # des evals de 14 minutes sur tower.
  #
  # PIEGE VERIFIE : on ne peut pas filtrer la source. `builtins.getFlake`
  # refuse un chemin du store ("the string '/nix/store/...-winnie-src-filtre'
  # is not allowed to refer to a store path"), or `builtins.path {filter=...}`
  # rend justement un chemin du store. Les seules sorties sont de reduire
  # l'arbre lui-meme (CARGO_TARGET_DIR hors du depot) ou de ne plus passer par
  # getFlake du tout (importer les fichiers du module par chemin).
  winnieFlake = builtins.getFlake (toString /home/marc/git/winnie);

  pin = name: binary:
    pkgs.runCommand "${name}-pinned" {} ''
      install -Dm755 ${binary} $out/bin/${name}
    '';

  backendBin = pin "winnie-backend" /home/marc/git/winnie/backend/target/release/winnie-backend;
  ingestBin = pin "winnie-ingest" /home/marc/git/winnie/ingest/target/release/winnie-ingest;

  appDist = builtins.path {
    path = /home/marc/git/winnie/app/dist;
    name = "winnie-ui-dist";
  };
  appIndex = builtins.path {
    path = /home/marc/git/winnie/app/dist/index.html;
    name = "winnie-ui-index";
  };

  # Le backend et l'ingest lisent OPENROUTER_API_KEY : la cle vit dans le .env
  # de hermes (source unique, deja utilisee par l'agent). L'unite ci-dessous en
  # extrait la seule affectation utile dans un fichier 0640 lisible par le
  # groupe winnie, parce que systemd refuse un EnvironmentFile qui n'est pas un
  # fichier de variables.
  openrouterEnv = "/var/lib/winnie/openrouter.env";
in {
  imports = [
    # Infra + unité winnie-backend (options services.winnie.backend.*).
    winnieFlake.nixosModules.default
  ];

  # Garage est deja en place pour tower (services/garage, buckets artifacts et
  # photos-*) : le module projet ne doit pas le redeclarer. Il ne fait alors que
  # provisionner le bucket winnie-media et sa cle, via winnie-bucket.
  services.winnie.manageGarage = false;

  services.winnie.backend = {
    enable = true;
    host = "127.0.0.1";
    port = 8787;
    oidcEnvFile = config.sops.secrets."oidc_env".path;
    openrouterEnvFile = openrouterEnv;
  };

  sops.secrets."oidc_env" = {
    sopsFile = ../../secrets/winnie.yml;
    key = "oidc_env";
    mode = "0640";
    group = "winnie";
  };

  systemd.services.winnie-ingest-env = {
    description = "Extract the OpenRouter key for Winnie (backend + nightly ingest)";
    wantedBy = ["multi-user.target"];
    before = ["winnie-backend.service" "winnie-ingest-nightly.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -e
      install -d -m 0750 -o root -g winnie /var/lib/winnie
      ${pkgs.gnugrep}/bin/grep '^OPENROUTER_API_KEY=' /var/lib/hermes/.hermes/.env > ${openrouterEnv}
      chown hermes:winnie ${openrouterEnv}
      chmod 0640 ${openrouterEnv}
    '';
  };

  systemd.services.winnie-backend = {
    after = ["winnie-ingest-env.service"];
    wants = ["winnie-bucket.service"];
    serviceConfig.ExecStart = lib.mkForce "${backendBin}/bin/winnie-backend";
    # Stripe (checkout des commandes) : la cle vit dans /var/lib/winnie/stripe.env
    # depuis le 10/11, hors sops (secrets d'ETAT generes sur la machine). Optionnel
    # ("-") : sans le fichier, /payments/config repond « disabled » et le reste de
    # l'API marche.
    serviceConfig.EnvironmentFile = ["-/var/lib/winnie/stripe.env"];
  };

  # Front Svelte 5 (build statique) : c'est la cible de la ressource Pangolin
  # winnie-frontend (winnie.marcpartensky.com, port 8888). Le port ici DOIT
  # rester celui de services/newt.
  systemd.services.winnie-frontend = {
    description = "Winnie front (Svelte 5 statique)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.static-web-server}/bin/static-web-server"
        "--host 127.0.0.1"
        "--port 8888"
        "--root ${appDist}"
        "--page-fallback ${appIndex}"
        "--health"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Serveur de dev Vite sur 8080 : cible de la ressource Pangolin winnie-dev
  # (dev.winnie.marcpartensky.com) et URL de l'APK debug. Il sert la SOURCE
  # (HMR), donc il tourne en tant que marc sur son working tree, pas depuis le
  # store.
  systemd.services.winnie-dev = {
    description = "Winnie dev server (Svelte/Vite HMR) sur 127.0.0.1:8080";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = "marc";
      Group = "users";
      WorkingDirectory = "/home/marc/git/winnie/app";
      ExecStart = "${pkgs.nodejs_22}/bin/node /home/marc/git/winnie/app/node_modules/vite/bin/vite.js";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };

  # Ingest nocturne : lit sa fenetre, son modele et ses zones dans Postgres
  # (`ingest_config`, edite depuis l'ecran Settings de l'app).
  systemd.services.winnie-ingest-nightly = {
    description = "Winnie nightly ingest (config-driven 01:00-08:00 window)";
    after = [
      "postgresql.service"
      "winnie-schema.service"
      "winnie-ingest-env.service"
      "network-online.target"
    ];
    wants = ["network-online.target"];
    requires = ["postgresql.service" "winnie-ingest-env.service"];
    path = [pkgs."poppler-utils"];
    serviceConfig = {
      # `exec` (et non `oneshot`) pour que RuntimeMaxSec s'applique : le batch
      # est un processus long, pas une tache d'activation.
      Type = "exec";
      User = "hermes";
      WorkingDirectory = "/var/lib/winnie";
      EnvironmentFile = openrouterEnv;
      Environment = [
        "DATABASE_URL=postgresql://winnie@127.0.0.1/winnie"
        "RUST_LOG=winnie_ingest=info"
      ];
      ExecStart = "${ingestBin}/bin/winnie-ingest nightly";
      RuntimeMaxSec = "27000s";
      TimeoutStartSec = "infinity";
    };
  };

  systemd.timers.winnie-ingest-nightly = {
    description = "Nightly Winnie ingest window";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 01:00:00";
      Persistent = true;
      Unit = "winnie-ingest-nightly.service";
    };
  };
}
