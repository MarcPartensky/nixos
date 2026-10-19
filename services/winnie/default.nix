# Module temporaire : active Winnie depuis le flake du projet.
#
# Ecarts assumes par rapport a la source de verite, a supprimer apres :
# 1. Le code Rust du working tree ne compile pas (backend/src reference
#    `winnie_backend::router` alors que la crate ne l'expose pas), donc le
#    package Nix du flake est inutilisable : on epingle le binaire compile par
#    cargo. Nix le copie dans le store, ce qui le protege du ramasse-miettes.
# 2. Le service backend est redeclare ici au lieu d'importer
#    `nixosModules.default`, qui tirerait ce package cassable.
# 3. Garage/S3 est desormais actif : le module du projet declare un groupe
#    `garage` statique que le DynamicUser du service garage de nixpkgs refuse
#    ("User or group with specified name already exists"). Le module du projet
#    epingle maintenant le service sur un compte statique garage (DynamicUser =
#    false), donc `manageGarage = true` est utilisable tel quel.
# L'infrastructure (user/groupe winnie, base PostgreSQL + schema, secret JWT)
# vient bien du projet via l'import ci-dessous.
{ config, pkgs, lib, ... }:
let
  backendBin = pkgs.runCommand "winnie-backend-pinned" { } ''
    install -Dm755 ${/home/marc/git/winnie/backend/target/release/winnie-backend} $out/bin/winnie-backend
  '';
  ingestBin = pkgs.runCommand "winnie-ingest-pinned" { } ''
    install -Dm755 ${/home/marc/git/winnie/ingest/target/release/winnie-ingest} $out/bin/winnie-ingest
  '';
in {
  sops.secrets."oidc_env" = {
    sopsFile = ../../secrets/winnie.yml;
    key = "oidc_env";
    mode = "0640";
    group = "winnie";
  };

  imports = [ /home/marc/git/winnie/services/winnie/default.nix ];

  services.winnie.manageGarage = true;

  # OIDC env file from sops (PKCE - no client_secret)
  systemd.services.winnie-oidc-secret = {
    description = "Generate winnie OIDC env file from sops";
    wantedBy = [ "multi-user.target" ];
    before = [ "winnie-backend.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/cp ${config.sops.secrets."oidc_env".path} /var/lib/winnie/oidc.env";
    };
  };

  # Front Svelte 5 (web statique, Vite) : `npm run build` dans
  # /home/marc/git/winnie/app -> app/dist, copie dans le store a l'evaluation,
  # servi en loopback ; Pangolin l'expose sur winnie.marcpartensky.com.
  # Rebuild du front = relancer `npm run build` puis un `nixos-rebuild switch`
  # (builtins.path est impur : la copie dans le store date de l'evaluation).
  # Le port ci-dessous DOIT etre celui de la ressource Pangolin
  # `winnie-frontend` dans services/newt : un desaccord donne un 502 sur le
  # domaine (le client newt met le port cible en cache, il faut le redemarrer).
  systemd.services.winnie-frontend = {
    description = "Winnie front (Svelte 5 statique)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.static-web-server}/bin/static-web-server"
        "--host 127.0.0.1"
        "--port 8888"
        "--root ${builtins.path { path = /home/marc/git/winnie/app/dist; name = "winnie-ui-dist"; }}"
        "--page-fallback ${builtins.path { path = /home/marc/git/winnie/app/dist/index.html; name = "winnie-ui-index"; }}"
        "--health"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.services.winnie-backend = {
    description = "Winnie backend (Rust/Axum, binaire epingle)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "postgresql.service"
      "winnie-schema.service"
      "winnie-jwt-secret.service"
      "winnie-oidc-secret.service"
      "winnie-bucket.service"
      "network.target"
    ];
    # s3.env is optional at the EnvironmentFile level, but when the bucket unit
    # exists the backend must read the key it writes: start after it so a fresh
    # boot does not come up without S3.
    wants = [ "winnie-bucket.service" ];
    requires = [ "postgresql.service" "winnie-jwt-secret.service" "winnie-oidc-secret.service" ];
    serviceConfig = {
      User = "winnie";
      Group = "winnie";
      WorkingDirectory = "/var/lib/winnie";
      # jwt.env est obligatoire, s3.env optionnel, oidc.env pour PKCE/Zitadel
      EnvironmentFile = [ "/var/lib/winnie/jwt.env" "-/var/lib/winnie/s3.env" "/var/lib/winnie/oidc.env" ];
      Environment = [
        "DATABASE_URL=postgresql://winnie@127.0.0.1/winnie"
        "SERVER_HOST=127.0.0.1"
        "SERVER_PORT=8787"
        "RUST_LOG=info"
        "RESTAURANTS_JSON=${/home/marc/git/winnie/data/restaurants.json}"
        "CHAT_BACKEND=openrouter"
      ];
      ExecStart = "${backendBin}/bin/winnie-backend";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # The nightly batch reads its window, model, and zones from Postgres
  # (`ingest_config`, edited in the app's Settings screen). This unit only
  # makes the OpenRouter key available: the agent's .env contains a bare token
  # that systemd would reject as an EnvironmentFile, so copy the one useful
  # assignment into a dedicated 0640 file.
  systemd.services.winnie-ingest-env = {
    description = "Extract the OpenRouter key for the Winnie nightly ingest";
    wantedBy = [ "multi-user.target" ];
    before = [ "winnie-ingest-nightly.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -e
      install -d -m 0750 -o root -g winnie /var/lib/winnie
      ${pkgs.gnugrep}/bin/grep '^OPENROUTER_API_KEY=' /var/lib/hermes/.hermes/.env > /var/lib/winnie/openrouter.env
      chown hermes:winnie /var/lib/winnie/openrouter.env
      chmod 0640 /var/lib/winnie/openrouter.env
    '';
  };

  systemd.services.winnie-ingest-nightly = {
    description = "Winnie nightly ingest (config-driven 01:00-08:00 window)";
    after = [
      "postgresql.service"
      "winnie-schema.service"
      "winnie-ingest-env.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "postgresql.service" "winnie-ingest-env.service" ];
    path = [ pkgs."poppler-utils" ];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      WorkingDirectory = "/var/lib/winnie";
      EnvironmentFile = "/var/lib/winnie/openrouter.env";
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
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 01:00:00";
      Persistent = true;
      Unit = "winnie-ingest-nightly.service";
    };
  };
}
