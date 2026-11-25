# services/reactive-resume/default.nix
# Reactive Resume (github.com/AmruthPillai/Reactive-Resume) on cv.marcpartensky.com.
#
# Inspired by marc's personal docker-compose (github.com/marcpartensky/docker,
# services/resume/compose.yml), but simplified for the current version of
# the image (>= v5.1): since v5.1 the PDF is generated on the browser side
# (@react-pdf/renderer), so no more "printer" container (browserless/chrome)
# nor PRINTER_*/BROWSERLESS_*. S3 storage (Minio in the old setup) is
# optional since the same version: if the S3_* are empty the app stores the
# uploads locally (/app/data) -- we keep that to avoid deploying Minio.
#
# No nixpkgs package for this app (Node/NestJS): OCI container via podman
# (virtualisation.oci-containers, cf. services/chhoto for the same pattern).
# --network=host (instead of a mapped port) because the app must talk to Postgres on
# 127.0.0.1:5432 like a native service -- same loopback convention as the
# rest of tower, the firewall stays closed on this port (assertion at the bottom).
{
  config,
  lib,
  pkgs,
  ...
}: {
  sops.secrets."reactive-resume/db_password" = {
    key = "reactive_resume_db_password";
    sopsFile = ../../secrets/reactive-resume.yml;
    # read by reactive-resume-db-password.service (User=postgres); the app
    # itself reads the password via the sops template below, not this file.
    owner = "postgres";
  };

  sops.secrets."reactive-resume/auth_secret" = {
    key = "reactive_resume_auth_secret";
    sopsFile = ../../secrets/reactive-resume.yml;
  };

  sops.templates."reactive-resume.env" = {
    content = ''
      TZ=America/New_York
      APP_URL=https://cv.marcpartensky.com
      PORT=8098
      DATABASE_URL=postgresql://reactive-resume:${config.sops.placeholder."reactive-resume/db_password"}@127.0.0.1:5432/reactive-resume
      AUTH_SECRET=${config.sops.placeholder."reactive-resume/auth_secret"}
      # Registration open for now: the entry point is anyway
      # behind the Pangolin SSO (auth.sso-enabled below). Switch
      # back to true once marc's account is created if we want to close registrations.
      FLAG_DISABLE_SIGNUPS=false
    '';
  };

  services.postgresql = {
    ensureDatabases = ["reactive-resume"];
    ensureUsers = [
      {
        name = "reactive-resume";
        ensureDBOwnership = true;
      }
    ];
    # types.lines: concatenates with the rules of the other modules (postgres,
    # vaultwarden, gitea...) instead of replacing them. Same mkOverride 10 as
    # vaultwarden, pattern verified working (cf skill marc-nixos-config).
    authentication = lib.mkOverride 10 ''
      host    reactive-resume  reactive-resume  127.0.0.1/32   md5
    '';
  };

  # Aligns the postgres role password with the sops secret used by
  # DATABASE_URL (ensureUsers does not set a password). Same pattern as
  # vaultwarden-db-password.
  #
  # PITFALL EXPERIENCED (11/11/2026, 00:24): this unit can start BEFORE sops-nix
  # has placed the secret file with its owner. The `cat` then exited
  # with "Permission denied", psql received an EMPTY password and answered
  # "empty string is not a valid password, clearing password": the role
  # lost its password, the app went into a restart loop
  # (204 restarts in 4 h) on "password authentication failed". The script
  # therefore now refuses to run if the secret is not readable.
  systemd.services.reactive-resume-db-password = {
    description = "Aligns the postgres role password of reactive-resume with the sops secret";
    wantedBy = ["multi-user.target"];
    before = ["podman-reactive-resume.service"];
    requiredBy = ["podman-reactive-resume.service"];
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      secret=${config.sops.secrets."reactive-resume/db_password".path}
      if [ ! -r "$secret" ]; then
        echo "reactive-resume: secret $secret unreadable (sops not placed yet), leaving the password untouched" >&2
        exit 1
      fi
      pw="$(cat "$secret")"
      if [ -z "$pw" ]; then
        echo "reactive-resume: empty secret, leaving the password untouched" >&2
        exit 1
      fi
      ${config.services.postgresql.package}/bin/psql -v pw="$pw" <<'SQL'
      ALTER ROLE "reactive-resume" WITH PASSWORD :'pw';
      SQL
    '';
  };

  # Local uploads (no S3/Minio). uid/gid 1000 = user "node" of the official
  # image amruthpillai/reactive-resume.
  systemd.tmpfiles.rules = [
    "d /var/lib/reactive-resume 0750 1000 1000 -"
    "d /var/lib/reactive-resume/data 0750 1000 1000 -"
  ];

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.reactive-resume = {
    image = "docker.io/amruthpillai/reactive-resume:v5.2";
    autoStart = true;
    volumes = ["/var/lib/reactive-resume/data:/app/data"];
    environmentFiles = [config.sops.templates."reactive-resume.env".path];
    extraOptions = [
      "--network=host"
      "--pull=newer"
      "--health-cmd=node -e \"fetch('http://127.0.0.1:8098/api/health').then((r) => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1));\""
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
    ];
  };

  systemd.services."podman-reactive-resume" = {
    after = ["network-online.target" "postgresql.service" "reactive-resume-db-password.service"];
    wants = ["network-online.target"];
    requires = ["reactive-resume-db-password.service"];
  };

  # Public Pangolin resource: schema `proxy-resources` + `protocol`
  # (the one that actually works on this controller, cf gitea/jellyfin).
  # SSO enabled: closes access (including registration) behind Zitadel.
  services.newt.blueprint.proxy-resources.reactive-resume = {
    name = "reactive-resume";
    protocol = "http";
    full-domain = "cv.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8098;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8098;
          path = "/api/health";
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

  # Guard rail: never a port open on the LAN (--network=host exposes 8098 on
  # all the host interfaces, only the firewall protects from direct LAN).
  assertions = [
    {
      assertion = !(lib.elem 8098 config.networking.firewall.allowedTCPPorts);
      message = "reactive-resume: port 8098 must not be open on the firewall (exposure only via Pangolin/newt).";
    }
  ];
}
