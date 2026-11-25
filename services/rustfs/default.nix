# services/rustfs/default.nix
# RustFS: S3 object storage server (replacement for MinIO, abandoned
# upstream) for build artifacts (APK, IPA, archives) + the rustfs-mcp MCP
# that drives them from hermes.
#
# Server: upstream NixOS module (github:rustfs/rustfs, nix/rustfs-module.nix)
# pinned to tag 1.0.3 (rev 331fb89). The upstream default package
# compiles everything from sources (rust-overlay + nixpkgs-unstable, very long):
# replaced by the static musl binary from release 1.0.3 (fetchurl).
#
# Ports (loopback only, never exposed to the firewall):
#   - 127.0.0.1:9000: S3 API
#   - 127.0.0.1:9001: web console (admin)
#
# Root credentials: secrets/rustfs.yml (sops, keys access_key/secret_key),
# read by the service via LoadCredential and by the MCP wrapper at startup.
#
# Bucket `artifacts` (prefixes per project: winnie/, hermes-mobile/, ...) created
# by an idempotent oneshot unit after the server starts.
#
# MCP: rustfs-mcp (github:rustfs/mcp, rev 5126e9a) over stdio, spawned by
# hermes; it is a generic S3 MCP (--endpoint-url), it would also work
# against Garage. The crate is not in nixpkgs, hence the buildRustPackage.
{
  config,
  lib,
  pkgs,
  ...
}: let
  rustfsFlake = builtins.getFlake "github:rustfs/rustfs/331fb896285a7686f927baf8d9d4dc2d3d3a10a9";

  # Official binary of release 1.0.3 (static musl, x86_64); the zip
  # contains a single file `rustfs`.
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
      description = "RustFS object storage server (official musl binary)";
      homepage = "https://rustfs.com";
      license = lib.licenses.asl20;
      platforms = ["x86_64-linux"];
      mainProgram = "rustfs";
    };
  };

  # Official RustFS MCP (crate `rustfs-mcp`). Default features (io-uring):
  # upstream builds them with tokio_unstable (cf. its Dockerfile).
  # doCheck = false: upstream CI covers the tests, we only compile the binary.
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

  # stdio wrapper: hermes spawns this script; it reads the sops keys (never in
  # the nix store) and points the MCP at the local S3 API (automatic path-style
  # for a custom endpoint).
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
  # Client secret of the Zitadel OIDC app (console SSO): systemd env
  # file, so a single line `RUSTFS_IDENTITY_OPENID_CLIENT_SECRET=...`.
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
      # Public origin (scheme + authority, without path): console success
      # redirect and logout fallback.
      RUSTFS_BROWSER_REDIRECT_URL = "https://rustfs.marcpartensky.com";
      # Console SSO via Zitadel (app "RustFS Console" of the Zitadel project
      # "rustfs"). Fixed redirect_uri: the console is behind newt/traefik,
      # the value derived from the request would be wrong (hermes-webui trap).
      RUSTFS_IDENTITY_OPENID_ENABLE = "on";
      RUSTFS_IDENTITY_OPENID_CONFIG_URL = "https://auth.marcpartensky.com/.well-known/openid-configuration";
      RUSTFS_IDENTITY_OPENID_CLIENT_ID = "396704864681394476";
      RUSTFS_IDENTITY_OPENID_SCOPES = "openid,profile,email";
      RUSTFS_IDENTITY_OPENID_REDIRECT_URI = "https://rustfs.marcpartensky.com/rustfs/admin/v3/oidc/callback/default";
      RUSTFS_IDENTITY_OPENID_REDIRECT_URI_DYNAMIC = "off";
      RUSTFS_IDENTITY_OPENID_DISPLAY_NAME = "Zitadel";
      # Zitadel puts the PROJECT ID (not the client_id) in the `aud` claim of
      # the ID token: without this list, the check fails with
      # "Invalid audiences: <projectId> is not a trusted audience".
      RUSTFS_IDENTITY_OPENID_OTHER_AUDIENCES = "396704857517457708";
      # RustFS policy assigned to any account authenticated by this provider
      # (single-user: the Zitadel role check restricts who can authenticate).
      RUSTFS_IDENTITY_OPENID_ROLE_POLICY = "consoleAdmin";
      RUSTFS_IDENTITY_OPENID_EMAIL_CLAIM = "email";
      RUSTFS_IDENTITY_OPENID_USERNAME_CLAIM = "preferred_username";
    };
  };

  # The OIDC client secret arrives via a systemd env file (sops), not via the nix store.
  systemd.services.rustfs.serviceConfig.EnvironmentFile = config.sops.secrets."rustfs/oidc_env".path;

  # Idempotent creation of the `artifacts` bucket once the S3 API is up.
  systemd.services.rustfs-bucket = {
    description = "RustFS: idempotent creation of the artifacts bucket";
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

  # Console exposed via Pangolin (newt, site "tower"): NO Pangolin SSO,
  # a single auth layer = the console's Zitadel OIDC (like git/hermes).
  # Target 127.0.0.1:9001 (loopback: only newt, which runs on tower, reaches it;
  # nothing open on the firewall). Schema `proxy-resources` + `protocol` (the old
  # schema of this Pangolin controller, cf. skill selfhosted-remote-access /
  # references/pangolin-blueprint.md). Free domain verified on 24/10/2026.
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
