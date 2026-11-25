# Local Nix binary cache: atticd (server) with storage ON DISK, and
# automatic push of each build via the Nix daemon's post-build-hook.
#
# Storage is local (`type = "local"`, folder /var/lib/atticd/storage):
# a single-machine binary cache does not need an S3 engine. The S3 backend
# to rustfs was removed on 2026-11-11: rustfs used ~1 core in bursts of
# walk_dir at rest (measured with atop) for a cache that only tower reads.
#
# Goal: no longer recompile the home-grown packages (kasmvnc, *-mcp, hermes...)
# after a GC, a rollback or a `nix flake update`, and serve as a substituter
# for the other machines of the mesh the day it is exposed. The pushes skip the
# paths already available on cache.nixos.org (upstream cache keys), so the
# cache contains only what tower alone produces.
#
# The signing key is managed by the server (managed signing): it lives
# in the atticd database and changes if the database is recreated; `attic cache info
# nixos` displays it, and it is pinned in `nix.settings.trusted-public-keys`
# (phase 2 section at the bottom of the file). A key change requires repainting
# this line AND re-walking what the old key had signed.
{ pkgs, config, lib, ... }:
let
  stateDir = "/var/lib/atticd";
  cacheName = "nixos";

  # Same content as the config-file checked by the nixpkgs module, but
  # referenceable here for atticadm (the module does not expose it).
  serverConfig = (pkgs.formats.toml { }).generate "atticd-server.toml" config.services.atticd.settings;

  # Bootstrap token rights: exactly what is needed (pull to read, push
  # for the hook, create/configure for the bootstrap). No --destroy-cache.
  tokenClaims = "--pull '*' --push '*' --create-cache '*' --configure-cache '*' --configure-cache-retention '*'";
in
{
  services.atticd = {
    enable = true;
    # JWT secret (signing of the API tokens), generated on the first switch in
    # /var/lib/atticd/jwt.env (root, 0600). Outside sops: hermes cannot
    # create sops secrets; it is local state of the service, like the DB.
    environmentFile = "${stateDir}/jwt.env";
    settings = {
      # 8484: dedicated port. 8080 is already taken by the winnie dev server (Vite,
      # wildcard bind); binding the loopback there failed silently and the
      # attic clients fell onto Vite (SPA/404 instead of the attic API).
      listen = "127.0.0.1:8484";
      storage = {
        # Local storage: no S3 backend, hence no extra service to
        # maintain nor object scans. Path under stateDir, the nixpkgs
        # module creates the folder and attaches it to the service.
        type = "local";
        path = "${stateDir}/storage";
      };
    };
  };

  # A single env file: the JWT generated above. No more S3 creds (local
  # storage) and therefore no more dependency on rustfs.
  systemd.services.atticd = {
    serviceConfig.EnvironmentFile = lib.mkForce [
      "${stateDir}/jwt.env"
    ];
  };

  # Generates the JWT secret only once (idempotent, survives switches).
  system.activationScripts.atticd-jwt = ''
    install -d -m 0700 ${stateDir}
    if [ ! -s ${stateDir}/jwt.env ]; then
      umask 077
      echo "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=$(${pkgs.openssl}/bin/openssl genrsa -traditional 4096 | ${pkgs.coreutils}/bin/base64 -w0)" > ${stateDir}/jwt.env
    fi
  '';

  # Bootstrap (idempotent, at boot and after switch): API token, "nixos" cache
  # public for reading, client configs (root for the hook, hermes and marc
  # for manual use).
  systemd.services.atticd-bootstrap = {
    description = "Bootstrap of the attic binary cache (token, cache, client configs)";
    after = [ "atticd.service" ];
    requires = [ "atticd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "${stateDir}/jwt.env";
    };
    path = [ pkgs.attic-client pkgs.attic-server pkgs.coreutils pkgs.curl ];
    script = ''
      set -eu
      # atticd reaches the "active" state BEFORE finishing its migrations and
      # listening: the bootstrap that immediately follows fell on
      # "Connection refused" on _api/v1/cache-config. Wait for the socket.
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:8484/ 2>/dev/null \
           || ${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8484/ 2>/dev/null | grep -qE '^[0-9]{3}$'; then
          break
        fi
        sleep 1
      done

      token_file=${stateDir}/token
      if [ ! -s "$token_file" ]; then
        atticadm -f ${serverConfig} make-token --sub tower --validity '10 years' \
          ${tokenClaims} > "$token_file"
        chmod 0600 "$token_file"
      fi

      mkdir -p ${stateDir}/attic /var/lib/hermes/.config/attic /home/marc/.config/attic
      chown root:root ${stateDir}/attic
      chown hermes:hermes /var/lib/hermes/.config/attic
      chown marc:users /home/marc/.config/attic

      write_config() {
        # $1 path, $2 user, $3 group
        printf 'default-server = "tower"\n\n[servers.tower]\nendpoint = "http://127.0.0.1:8484"\ntoken = "%s"\n' \
          "$(cat "$token_file")" > "$1"
        chmod 0600 "$1"
        chown "$2:$3" "$1"
      }
      write_config ${stateDir}/attic/config.toml root root
      write_config /var/lib/hermes/.config/attic/config.toml hermes hermes
      write_config /home/marc/.config/attic/config.toml marc users

      export XDG_CONFIG_HOME=${stateDir}
      if ! attic cache info ${cacheName} >/dev/null 2>&1; then
        attic cache create ${cacheName} --public
      fi
    '';
  };

  # Pushes each output freshly built by the Nix daemon. A failure is
  # ignored: the cache is an accelerator, not a service guarantee.
  nix.settings.post-build-hook = pkgs.writeShellScript "attic-post-build-hook" ''
    set -u
    if [ -z "''${OUT_PATHS:-}" ]; then exit 0; fi
    export XDG_CONFIG_HOME=${stateDir}
    if [ -s ${stateDir}/attic/config.toml ]; then
      ${pkgs.attic-client}/bin/attic push ${cacheName} $OUT_PATHS \
        || echo "attic push failed (ignored)" >&2
    fi
  '';

  environment.systemPackages = [ pkgs.attic-client ];

  # Phase 2: substitute from the local cache first, then cache.nixos.org.
  # PITFALL: `nix.settings.substituters` REPLACES the nixpkgs default list,
  # it does not complete it. Declaring only the local cache would compile
  # locally any upstream path missing from the cache. Both must appear here.
  # The public key comes from `attic cache info nixos` (managed signing); it
  # changes if the atticd database is recreated, so re-verify after a
  # reset of stateDir.
  nix.settings.substituters = [
    "http://127.0.0.1:8484/${cacheName}"
    "https://cache.nixos.org/"
  ];
  nix.settings.trusted-public-keys = [ "nixos:mGLkZ8N9hIbCeznuZ79qCTDPfoifJ3EaNAJxbNKOiYk=" ];
}
