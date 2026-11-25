# services/rustfs/default.nix
# RustFS : serveur de stockage objet S3 (remplaçant de MinIO, abandonné en
# amont) pour les artifacts de build (APK, IPA, archives) + le MCP rustfs-mcp
# qui les pilote depuis hermes.
#
# Serveur : module NixOS upstream (github:rustfs/rustfs, nix/rustfs-module.nix)
# épinglé sur le tag 1.0.3 (rev 331fb89). Le package par défaut de l'upstream
# compile tout depuis les sources (rust-overlay + nixpkgs-unstable, très long) :
# remplacé par le binaire musl statique de la release 1.0.3 (fetchurl).
#
# Ports (loopback seul, jamais exposés au firewall) :
#   - 127.0.0.1:9000 : API S3
#   - 127.0.0.1:9001 : console web (admin)
#
# Credentials racine : secrets/rustfs.yml (sops, clés access_key/secret_key),
# lus par le service via LoadCredential et par le wrapper MCP au démarrage.
#
# Bucket `artifacts` (préfixes par projet : winnie/, hermes-mobile/, ...) créé
# par une unité oneshot idempotente après le démarrage du serveur.
#
# MCP : rustfs-mcp (github:rustfs/mcp, rev 5126e9a) en stdio, spawné par
# hermes ; c'est un MCP S3 générique (--endpoint-url), il marcherait aussi
# contre Garage. Le crate n'est pas dans nixpkgs, d'où le buildRustPackage.
{
  config,
  lib,
  pkgs,
  ...
}: let
  rustfsFlake = builtins.getFlake "github:rustfs/rustfs/331fb896285a7686f927baf8d9d4dc2d3d3a10a9";

  # Binaire officiel de la release 1.0.3 (musl statique, x86_64) ; le zip
  # contient un seul fichier `rustfs`.
  rustfs = pkgs.stdenvNoCC.mkDerivation {
    pname = "rustfs";
    version = "1.0.3";
    src = pkgs.fetchurl {
      url = "https://github.com/rustfs/rustfs/releases/download/1.0.3/rustfs-linux-x86_64-musl-v1.0.3.zip";
      hash = "sha256-KaCD8Vb+GiRvAzav4W/3f//lh2KOlzOUSNj0+6ONulQ=";
    };
    nativeBuildInputs = [pkgs.unzip];
    sourceRoot = ".";
    installPhase = ''
      runHook preInstall
      install -Dm755 rustfs $out/bin/rustfs
      runHook postInstall
    '';
    meta = {
      description = "RustFS object storage server (binaire musl officiel)";
      homepage = "https://rustfs.com";
      license = lib.licenses.asl20;
      platforms = ["x86_64-linux"];
      mainProgram = "rustfs";
    };
  };

  # MCP officiel RustFS (crate `rustfs-mcp`). Features par défaut (io-uring) :
  # l'upstream les construit avec tokio_unstable (cf. son Dockerfile).
  # doCheck = false : la CI amont couvre les tests, on ne compile que le binaire.
  rustfs-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "rustfs-mcp";
    version = "0.1.0";
    src = pkgs.fetchFromGitHub {
      owner = "rustfs";
      repo = "mcp";
      rev = "5126e9a87e53365c310d2f42d5e0cf4c30ef6a7c";
      hash = "sha256-qgdObysH4QiX4/QpTMk8Dg2IxqJVHSDYX28kLqaxTBE=";
    };
    cargoHash = "sha256-7MWyT7CzQRz+aMZvxWi19scVh6hvdtW1bmGthbIXb+M=";
    env.RUSTFLAGS = "--cfg tokio_unstable";
    doCheck = false;
    meta = {
      description = "RustFS MCP server (S3-compatible object storage)";
      homepage = "https://github.com/rustfs/mcp";
      license = lib.licenses.asl20;
      mainProgram = "rustfs-mcp";
    };
  };

  # Wrapper stdio : hermes spawn ce script ; il lit les clés sops (jamais dans
  # le store nix) et pointe le MCP sur l'API S3 locale (path-style automatique
  # pour un endpoint custom).
  mcpWrapper = pkgs.writeShellScript "rustfs-mcp-hermes" ''
    set -euo pipefail
    export AWS_ACCESS_KEY_ID="$(cat ${config.sops.secrets."rustfs/access_key".path})"
    export AWS_SECRET_ACCESS_KEY="$(cat ${config.sops.secrets."rustfs/secret_key".path})"
    export AWS_REGION="us-east-1"
    exec ${lib.getExe rustfs-mcp} --endpoint-url http://127.0.0.1:9000
  '';
in {
  imports = [rustfsFlake.nixosModules.rustfs];

  sops.secrets."rustfs/access_key" = {
    sopsFile = ../../secrets/rustfs.yml;
    key = "access_key";
    owner = "hermes";
    mode = "0400";
    restartUnits = ["rustfs.service"];
  };
  sops.secrets."rustfs/secret_key" = {
    sopsFile = ../../secrets/rustfs.yml;
    key = "secret_key";
    owner = "hermes";
    mode = "0400";
    restartUnits = ["rustfs.service"];
  };
  # Client secret de l'app OIDC Zitadel (SSO de la console) : fichier d'env
  # systemd, donc une seule ligne `RUSTFS_IDENTITY_OPENID_CLIENT_SECRET=...`.
  sops.secrets."rustfs/oidc_env" = {
    sopsFile = ../../secrets/rustfs.yml;
    key = "oidc_env";
    restartUnits = ["rustfs.service"];
  };

  services.rustfs = {
    enable = true;
    package = rustfs;
    volumes = ["/var/lib/rustfs"];
    address = "127.0.0.1:9000";
    consoleEnable = true;
    consoleAddress = "127.0.0.1:9001";
    accessKeyFile = config.sops.secrets."rustfs/access_key".path;
    secretKeyFile = config.sops.secrets."rustfs/secret_key".path;
    extraEnvironmentVariables = {
      # Origine publique (scheme + autorité, sans chemin) : redirect de succès
      # de la console et fallback de logout.
      RUSTFS_BROWSER_REDIRECT_URL = "https://rustfs.marcpartensky.com";
      # SSO console via Zitadel (app "RustFS Console" du projet Zitadel
      # "rustfs"). redirect_uri fixe : la console est derrière newt/traefik,
      # la valeur dérivée de la requête serait fausse (piège hermes-webui).
      RUSTFS_IDENTITY_OPENID_ENABLE = "on";
      RUSTFS_IDENTITY_OPENID_CONFIG_URL = "https://auth.marcpartensky.com/.well-known/openid-configuration";
      RUSTFS_IDENTITY_OPENID_CLIENT_ID = "396704864681394476";
      RUSTFS_IDENTITY_OPENID_SCOPES = "openid,profile,email";
      RUSTFS_IDENTITY_OPENID_REDIRECT_URI = "https://rustfs.marcpartensky.com/rustfs/admin/v3/oidc/callback/default";
      RUSTFS_IDENTITY_OPENID_REDIRECT_URI_DYNAMIC = "off";
      RUSTFS_IDENTITY_OPENID_DISPLAY_NAME = "Zitadel";
      # Zitadel met l'ID du PROJET (pas le client_id) dans le claim `aud` de
      # l'ID token : sans cette liste, la vérification échoue en
      # « Invalid audiences: <projectId> is not a trusted audience ».
      RUSTFS_IDENTITY_OPENID_OTHER_AUDIENCES = "396704857517457708";
      # Policy RustFS assignée à tout compte authentifié par ce provider
      # (mono-utilisateur : le role check Zitadel restreint qui peut s'authentifier).
      RUSTFS_IDENTITY_OPENID_ROLE_POLICY = "consoleAdmin";
      RUSTFS_IDENTITY_OPENID_EMAIL_CLAIM = "email";
      RUSTFS_IDENTITY_OPENID_USERNAME_CLAIM = "preferred_username";
    };
  };

  # Le client secret OIDC arrive par fichier d'env systemd (sops), pas par le store nix.
  systemd.services.rustfs.serviceConfig.EnvironmentFile = config.sops.secrets."rustfs/oidc_env".path;

  # Création idempotente du bucket `artifacts` une fois l'API S3 debout.
  systemd.services.rustfs-bucket = {
    description = "RustFS : création idempotente du bucket artifacts";
    wantedBy = ["multi-user.target"];
    after = ["rustfs.service"];
    wants = ["rustfs.service"];
    path = [pkgs.rclone pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      export RCLONE_CONFIG_RUSTFS_TYPE=s3
      export RCLONE_CONFIG_RUSTFS_PROVIDER=Other
      export RCLONE_CONFIG_RUSTFS_ACCESS_KEY_ID="$(cat ${config.sops.secrets."rustfs/access_key".path})"
      export RCLONE_CONFIG_RUSTFS_SECRET_ACCESS_KEY="$(cat ${config.sops.secrets."rustfs/secret_key".path})"
      export RCLONE_CONFIG_RUSTFS_ENDPOINT=http://127.0.0.1:9000
      export RCLONE_CONFIG_RUSTFS_REGION=us-east-1
      for _ in $(seq 1 30); do
        rclone lsd rustfs: >/dev/null 2>&1 && break
        sleep 2
      done
      rclone lsd rustfs: | grep -qw artifacts || rclone mkdir rustfs:artifacts
    '';
  };

  services.hermes-agent.mcpServers.rustfs = {
    command = "${mcpWrapper}";
    timeout = 60;
  };

  # Console exposée via Pangolin (newt, site "tower") : PAS de SSO Pangolin,
  # une seule couche d'auth = l'OIDC Zitadel de la console (comme git/hermes).
  # Cible 127.0.0.1:9001 (loopback : seul newt, qui tourne sur tower, la joint ;
  # rien d'ouvert au firewall). Schéma `proxy-resources` + `protocol` (l'ancien
  # schéma de ce contrôleur Pangolin, cf. skill selfhosted-remote-access /
  # references/pangolin-blueprint.md). Domaine libre vérifié le 24/10/2026.
  services.newt.blueprint.proxy-resources.rustfs-console = {
    name = "rustfs-console";
    protocol = "http";
    full-domain = "rustfs.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 9001;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 9001;
          path = "/rustfs/console/health";
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
}
