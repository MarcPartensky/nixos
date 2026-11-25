# services/garage/default.nix
# Garage: S3 object storage (Rust, deuxfleurs) for the build artifacts
# (APK, IPA, archives: what winnie and hermes-mobile deposit in the bucket
# `artifacts`) + the S3 MCP that drives them from hermes.
#
# Replaces RustFS (removed on 2026-11-11): rustfs used ~1 core in bursts of
# walk_dir at rest (atop measurement: 96 to 113 % of a core per 10 s sample
# with no client at all) for a single-machine use. Garage is a single binary,
# without an object scanner, with a single-node mode.
#
# Ports (loopback only, never exposed on the firewall):
#   - 127.0.0.1:3900: S3 API
#   - 127.0.0.1:3901: inter-node RPC (a single machine here)
#   - 127.0.0.1:3903: admin API (garage CLI)
#
# Secrets: generated at activation in /var/lib/garage (rpc_secret in hex,
# admin_token), like atticd's JWT: these are STATE secrets of the service,
# not shared identifiers to enter (hermes cannot write a
# sops file, it does not have tower's age key). The application S3 key, for its part, is created
# by the bootstrap (idempotent oneshot unit) and deposited readable by hermes
# in /var/lib/garage/s3-key.env.
#
# No web console: Garage does not have one. The clients are the S3 MCP and the CLIs
# (rclone, aws). The admin API (3903) stays on loopback.
{ config, lib, pkgs, ... }:
let
  stateDir = "/var/lib/garage";
  # One bucket per source: S3 has no real folders, a prefix per
  # project is enough for the artifacts but the photos come from distinct
  # sources (camera, WhatsApp, Messenger) that we want to be able to isolate,
  # count and back up separately.
  buckets = [
    "artifacts"
    "photos-camera"
    "photos-whatsapp"
    "photos-messenger"
    # PUBLIC bucket, the only one with website mode enabled below: any
    # object put there is readable by anyone who knows the URL, without signature or
    # session. It is this bucket that receives the files shared by short link
    # (services/share-mcp). Never deposit there what must stay private:
    # artifacts and photos-* stay, for their part, inaccessible anonymously even if
    # the web endpoint is reachable (Garage exposes to the public only the buckets
    # marked website).
    "public"
  ];
  # Path of the health placeholder: serves as probe for the Pangolin healthcheck
  # (Garage answers 404 on the root of a bucket without index.html, so a
  # probe on /public/ would mark the target unhealthy and Pangolin would drop it
  # from the load-balancer).
  healthKey = "_health.txt";
  keyName = "hermes";

  # S3 MCP over stdio. `rustfs-mcp` (github:rustfs/mcp) is a GENERIC S3
  # client: it takes --endpoint-url and does path-style for a custom
  # endpoint, so it drives Garage without change. It is not in nixpkgs,
  # hence the buildRustPackage; its default features (io-uring) require
  # tokio_unstable, as in the upstream Dockerfile.
  s3-mcp = pkgs.rustPlatform.buildRustPackage {
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
      description = "S3-compatible MCP (generic client, drives Garage)";
      homepage = "https://github.com/rustfs/mcp";
      license = lib.licenses.asl20;
      mainProgram = "rustfs-mcp";
    };
  };

  # stdio wrapper: hermes spawns this script, which reads the application key generated
  # by garage-bootstrap (never a hardcoded secret in the nix store).
  mcpWrapper = pkgs.writeShellScript "garage-s3-mcp-hermes" ''
    set -euo pipefail
    # shellcheck disable=SC1091
    . ${stateDir}/s3-key.env
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    exec ${lib.getExe s3-mcp} --endpoint-url http://127.0.0.1:3900
  '';
in
{
  services.garage = {
    enable = true;
    package = pkgs.garage;
    logLevel = "info";
    settings = {
      metadata_dir = "${stateDir}/meta";
      data_dir = "${stateDir}/data";
      db_engine = "sqlite";
      # Single-node: no redundancy to manage, a single disk.
      replication_factor = 1;
      consistency_mode = "consistent";
      rpc_bind_addr = "127.0.0.1:3901";
      rpc_public_addr = "127.0.0.1:3901";
      rpc_secret_file = "${stateDir}/rpc_secret";
      s3_api = {
        api_bind_addr = "127.0.0.1:3900";
        s3_region = "garage";
      };
      admin = {
        api_bind_addr = "127.0.0.1:3903";
        admin_token_file = "${stateDir}/admin_token";
      };
      # "website" HTTP endpoint: serves in path-style /<bucket>/<key> the
      # buckets marked website (see the bootstrap). Loopback only, exposed to
      # the public only by the Pangolin resource files.marcpartensky.com
      # (services/share-mcp), without SSO since the short links point at it.
      web = {
        bind_addr = "127.0.0.1:3902";
      };
    };
  };

  # The nixpkgs module runs as DynamicUser by default: the secret
  # files generated at activation (root) would then be unreadable for the
  # service. Static user instead, owner of its secrets.
  users.groups.garage = { };
  users.users.garage = {
    isSystemUser = true;
    group = "garage";
    home = stateDir;
    description = "Garage object storage";
  };

  systemd.services.garage.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "garage";
    Group = "garage";
  };

  # Instance secrets, generated once: regenerating them would change the
  # rpc_secret and make the existing data unreadable.
  # The folder stays 0755 (traversable): hermes must be able to read the
  # s3-key.env that the bootstrap deposits there. The secrets themselves are 0400
  # garage, so unreadable for anyone else.
  system.activationScripts.garage-secrets = ''
    install -d -m 0755 -o garage -g garage ${stateDir}
    if [ ! -s ${stateDir}/rpc_secret ]; then
      umask 077
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${stateDir}/rpc_secret
      ${pkgs.openssl}/bin/openssl rand -base64 32 > ${stateDir}/admin_token
    fi
    chown garage:garage ${stateDir}/rpc_secret ${stateDir}/admin_token
    chmod 0400 ${stateDir}/rpc_secret ${stateDir}/admin_token
  '';

  # Idempotent bootstrap: node layout, application S3 key, bucket.
  # The `garage` CLI reads /etc/garage.toml (set by the module) and the admin_token.
  systemd.services.garage-bootstrap = {
    description = "Garage: single-node layout, S3 key ${keyName}, buckets (artifacts, photos-*)";
    wantedBy = [ "multi-user.target" ];
    after = [ "garage.service" ];
    requires = [ "garage.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };
    path = [ pkgs.garage pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    script = ''
      set -eu
      export GARAGE_CONFIG_FILE=/etc/garage.toml

      # The service reaches the "active" state before listening: wait for the admin API.
      for _ in $(seq 1 30); do
        garage status >/dev/null 2>&1 && break
        sleep 2
      done

      node_id="$(garage node id -q | cut -d@ -f1)"
      layout="$(garage layout show 2>&1)"
      if ! printf '%s' "$layout" | grep -q "$node_id"; then
        garage layout assign -z dc1 -c 10G "$node_id"
        layout="$(garage layout show 2>&1)"
      fi
      if printf '%s' "$layout" | grep -qi "staged\|not yet committed"; then
        # `layout apply --version N` requires N = current version + 1: the
        # initial version of a fresh cluster is not 0, so read it instead of hardcoding 1.
        cur="$(printf '%s' "$layout" | sed -n 's/^Current cluster layout version: *//p' | tr -dc '0-9')"
        : ''${cur:=0}
        echo "$layout" >&2
        garage layout apply --version $((cur + 1))
      fi

      garage key info ${keyName} >/dev/null 2>&1 || garage key create ${keyName} >/dev/null
      for b in ${lib.concatStringsSep " " buckets}; do
        garage bucket create "$b" >/dev/null 2>&1 || true
        garage bucket allow --read --write "$b" --key ${keyName}
      done

      # Only the public bucket switches to website mode (anonymous read via
      # the web endpoint). The others stay private: Garage serves anonymously
      # only the buckets marked website.
      garage bucket website --allow public

      # S3 credentials for the non-root clients (MCP wrapper on the hermes side).
      info="$(garage key info --show-secret ${keyName})"
      key_id="$(printf '%s\n' "$info" | sed -n 's/^Key ID: *//p')"
      key_secret="$(printf '%s\n' "$info" | sed -n 's/^Secret key: *//p')"
      if [ -z "$key_id" ] || [ -z "$key_secret" ]; then
        echo "garage: sortie de 'key info' inattendue, champs: $(printf '%s\n' "$info" | cut -d: -f1 | tr '\n' ' ')" >&2
        exit 1
      fi
      printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_REGION=garage\n' \
        "$key_id" "$key_secret" > ${stateDir}/s3-key.env
      chown hermes:hermes ${stateDir}/s3-key.env
      chmod 0400 ${stateDir}/s3-key.env
      unset key_secret info

      # Health placeholder of the public bucket: the garage CLI does not know
      # how to deposit an object, so it goes through the S3 API with the key we just
      # wrote. Without it, the Pangolin probe hits a bucket root without
      # index.html and receives 404 (target unhealthy, removed from the load-balancer).
      set -a
      . ${stateDir}/s3-key.env
      set +a
      printf 'ok\n' | ${pkgs.awscli2}/bin/aws --endpoint-url http://127.0.0.1:3900 \
        s3 cp - "s3://public/${healthKey}" --content-type text/plain >/dev/null
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    '';
  };

  services.hermes-agent.mcpServers.garage = {
    command = "${mcpWrapper}";
    timeout = 60;
  };
}
