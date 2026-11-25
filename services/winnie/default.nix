# services/winnie/default.nix
#
# Activation of Winnie on tower. The source of truth is the PROJECT's flake
# (/home/marc/git/winnie): its `nixosModules.default` declares the infrastructure
# (winnie user/group, PostgreSQL database + schema, JWT secret, Garage S3
# bucket) and the backend unit. This module only carries the activation, the
# sops secrets and the units that cannot live in the project flake: the
# static front (app/dist, built by npm OUTSIDE the sandbox), the Vite dev
# server and the nightly ingest.
#
# WHY getFlake AND NOT AN INPUT: the system flake stays clean (skill
# flake-separation) and the impure evaluation is already that of `nixos-rebuild
# --impure`. NEVER remove the import below without another path
# providing the same module: a removed import deletes the units at the next
# switch (experienced on 12/11: module removed from the system flake on 10/11, switch of
# 12/11 -> winnie-backend, winnie-frontend and winnie-dev gone, api and front
# in 502/503).
#
# ACCEPTED DEVIATION, to remove when the working tree is committed: the `backend`
# package of the flake builds from the GIT tree, yet the untracked
# modules of the working tree (handlers/agent.rs, mcp.rs, api_tokens.rs) are not
# there, so this package does not compile. We pin the binaries compiled by
# cargo in the repo; Nix copies them into the store, which protects them from GC.
# Consequences: a Rust change exists in prod only after `cargo build
# --release` IN the repo then a switch. Same for the front: `npm run build`
# then switch (builtins.path is impure, the copy dates from evaluation).
{
  config,
  pkgs,
  lib,
  ...
}: let
  # `path:` and not `git+file://`: the git form goes through libgit2, which refuses a
  # repository owned by another user ("not owned by current user") - yet
  # every nixos-rebuild runs as root via sudo, so git+file breaks each
  # switch.
  #
  # MEASURED COST (13/11): the winnie tree is 16 GB, of which 11.5 GB of `*/target/`,
  # across 72 570 files. A `path:` forces Nix to re-read all of it on EVERY
  # evaluation (`nix hash path /home/marc/git/winnie` does not finish in 280 s,
  # versus 1.3 s for the nixos repo that weighs 6 MB): this is the primary cause
  # of the 14-minute evals on tower.
  #
  # VERIFIED PITFALL: the source cannot be filtered. `builtins.getFlake`
  # refuses a store path ("the string '/nix/store/...-winnie-src-filtre'
  # is not allowed to refer to a store path"), yet `builtins.path {filter=...}`
  # returns exactly a store path. The only ways out are to shrink
  # the tree itself (CARGO_TARGET_DIR outside the repo) or to no longer go through
  # getFlake at all (import the module's files by path).
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

  # The backend and the ingest read OPENROUTER_API_KEY: the key lives in hermes's
  # .env (single source, already used by the agent). The unit below
  # extracts the single useful assignment into a 0640 file readable by the
  # winnie group, because systemd refuses an EnvironmentFile that is not a
  # variables file.
  openrouterEnv = "/var/lib/winnie/openrouter.env";
in {
  imports = [
    # Infra + winnie-backend unit (services.winnie.backend.* options).
    winnieFlake.nixosModules.default
  ];

  # Garage is already in place for tower (services/garage, artifacts and
  # photos-* buckets): the project module must not redeclare it. It then only
  # provisions the winnie-media bucket and its key, via winnie-bucket.
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
    # Stripe (order checkout): the key lives in /var/lib/winnie/stripe.env
    # since 10/11, outside sops (STATE secrets generated on the machine). Optional
    # ("-"): without the file, /payments/config answers "disabled" and the rest of
    # the API works.
    #
    # OIDC app "winnie": it lives in its OWN Zitadel project (role
    # "winnie", projectRoleCheck), so its client_id changed. The client_id
    # is not a secret: a generated file is enough. The whole block is set
    # AFTER the project module's (mkAfter) and the client-id is LAST,
    # so it overrides the sops oidc_env value (systemd: last file
    # wins) without having to rewrite secrets/winnie.yml.
    serviceConfig.EnvironmentFile = lib.mkAfter [
      "-/var/lib/winnie/stripe.env"
      (pkgs.writeText "winnie-oidc-client-id.env" "OIDC_CLIENT_ID=400636688415654188")
    ];
  };

  # Svelte 5 front (static build): it is the target of the Pangolin resource
  # winnie-frontend (winnie.marcpartensky.com, port 8888). The port here MUST
  # stay the one from services/newt.
  systemd.services.winnie-frontend = {
    description = "Winnie front (Svelte 5 static)";
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

  # Vite dev server on 8080: target of the Pangolin resource winnie-dev
  # (dev.winnie.marcpartensky.com) and URL of the debug APK. It serves the SOURCE
  # (HMR), so it runs as marc on his working tree, not from the
  # store.
  systemd.services.winnie-dev = {
    description = "Winnie dev server (Svelte/Vite HMR) on 127.0.0.1:8080";
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

  # Nightly ingest: reads its window, its model and its zones from Postgres
  # (`ingest_config`, edited from the app's Settings screen).
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
      # `exec` (and not `oneshot`) so that RuntimeMaxSec applies: the batch
      # is a long process, not an activation task.
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
