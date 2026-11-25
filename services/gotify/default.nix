# services/gotify/default.nix
{
  pkgs,
  config,
  lib,
  inputs,
  ...
}: let
  # Gotify v3 (native OIDC support) is not in the pinned nixpkgs 26.05
  # (2.9.1): same convention as herdr/kanidm in this repo, we instantiate
  # the unstable input for an isolated package.
  gotifyPkg = (import inputs.unstable { system = pkgs.stdenv.hostPlatform.system; }).gotify-server;
in {
  imports = [ ./options.nix ];

  # DEDICATED file, not the host's default sopsFile: gotify runs on
  # anywhere and its consumers (bridge, mesh-dashboard) on tower, so both
  # hosts must be able to decrypt the same values.
  sops.secrets = {
    "gotify/admin_password" = {
      sopsFile = ../../secrets/gotify.yml;
      key = "gotify_admin_password";
    };
    "gotify/db_password" = {
      sopsFile = ../../secrets/gotify.yml;
      key = "gotify_db_password";
      # read by gotify-db-password.service, which runs as User=postgres
      # (gotify itself reads the password via the sops template, not this file)
      owner = "postgres";
    };
  };

  sops.templates."gotify.env" = {
    content = ''
      GOTIFY_DEFAULTUSER_PASS=${config.sops.placeholder."gotify/admin_password"}
      GOTIFY_DATABASE_CONNECTION=host=localhost port=5432 user=gotify dbname=gotify password=${config.sops.placeholder."gotify/db_password"} sslmode=disable
    '';
  };

  services.gotify = {
    enable = true;
    package = gotifyPkg;
    stateDirectoryName = "gotify";

    environment = {
      GOTIFY_SERVER_PORT = "8070";
      # loopback only: exposure goes through the newt/Pangolin tunnel.
      # Without this setting the server binds [::]:8070 on all interfaces
      # (harmless as long as the port is not in networking.firewall.
      # allowedTCPPorts, but a single forgotten line would be enough to expose it).
      GOTIFY_SERVER_LISTENADDR = "127.0.0.1";
      GOTIFY_DATABASE_DIALECT = "postgres";
      GOTIFY_DEFAULTUSER_NAME = "admin";  # only used when creating a fresh database (this one already exists)
      GOTIFY_PASSSTRENGTH = "10";

      # OIDC / Zitadel SSO. PITFALL: Gotify 3.x names its variables WITHOUT
      # underscore between words (gotify.net/docs/config):
      #   GOTIFY_OIDC_CLIENTID, CLIENTSECRET, REDIRECTURL, USERNAMECLAIM.
      # The snake_case forms (GOTIFY_OIDC_CLIENT_ID, ...) are ignored
      # SILENTLY: the UI would show the SSO button but the flow would fail.
      GOTIFY_OIDC_ENABLED = "true";
      # OIDC PKCE app (type User Agent, auth method None) in its OWN
      # Zitadel project ("Gotify", role "gotify", projectRoleCheck): the role
      # "gotify" opens Gotify and nothing else. Gaining access = granting this
      # role. No secret (public client).
      GOTIFY_OIDC_CLIENTID = "400636680144486700";
      # redirect_uri registered in the Zitadel database (projections.apps7_oidc_configs)
      # = https://gotify.marcpartensky.com/auth/oidc/callback
      GOTIFY_OIDC_CLIENTSECRET = "";  # public PKCE client: no secret
      GOTIFY_OIDC_ISSUER = "https://auth.marcpartensky.com";
      GOTIFY_OIDC_REDIRECTURL = "https://gotify.marcpartensky.com/auth/oidc/callback";
      GOTIFY_OIDC_SCOPES = "openid,profile,email";  # "text-list" = COMMA separator, not space
      GOTIFY_OIDC_USERNAMECLAIM = "preferred_username";
      GOTIFY_OIDC_IDP_NAME = "Zitadel";
      GOTIFY_OIDC_AUTOREGISTER = "true";
      # marc's Zitadel user has the username "marc@marcpartensky.com" (so
      # preferred_username too): it does NOT land on the local "marc" account.
      # This flag links the OIDC identity to the local account of the same name
      # instead of opening a second account. The local account was renamed
      # "marc@marcpartensky.com" (UPDATE users: it carries the 4 applications
      # and the client tokens already in place) while staying admin, because
      # GroupsAdmin is empty -> the existing admin flag is kept.
      GOTIFY_OIDC_LINK_BY_USERNAME = "true";
    };

    environmentFiles = [
      config.sops.templates."gotify.env".path
    ];
  };

  # gotify depends on postgres: without these settings it crash-looped when a
  # switch restarted postgresql (RestartSec=100ms by default, 5 attempts, then
  # start-limit-hit before postgres accepts connections again).
  #
  # It ALSO depends on the newt tunnel: at startup, Gotify 3.x does an OIDC
  # discovery on https://auth.marcpartensky.com (Zitadel is behind Pangolin, so
  # via newt) and exits with FTL "failed to initialize OIDC provider ... 503" if
  # the tunnel is not yet up, which kills the service. Verified on 09/10/2026:
  # the first 2 startup attempts failed for this reason.
  # Hence after/wants newt + StartLimitIntervalSec = 0 (disables the systemd
  # rate-limit): the service retries indefinitely instead of staying dead until
  # the next switch after 10 failures in 60 s.
  systemd.services.gotify-server = {
    after = [ "postgresql.service" ] ++ lib.optional config.services.gotify.publishViaNewt "newt.service";
    wants = [ "postgresql.service" ] ++ lib.optional config.services.gotify.publishViaNewt "newt.service";
    unitConfig = {
      StartLimitIntervalSec = 0;
      StartLimitBurst = 10;
    };
    serviceConfig = {
      RestartSec = "5s";
    };
  };

  # SAME BUG AS VAULTWARDEN (verified 25/09/2026 by replaying the binary by
  # hand): ensureUsers creates the postgres role `gotify` WITHOUT a password,
  # while the effective pg_hba requires md5/scram for this role (services.postgresql.
  # authentication is a types.lines: all modules concatenate and the
  # rule `host gotify gotify 127.0.0.1/32 md5` comes BEFORE the generic
  # `host all all 127.0.0.1/32 trust`). Symptom: gotify-server exits
  # in 64 ms with status=2 and
  #   failed SASL auth: FATAL: password authentication failed for user "gotify"
  # then start-limit-hit. Fix: align the role with the sops secret already used
  # by GOTIFY_DATABASE_CONNECTION. Idempotent, replayed on each activation.
  systemd.services.gotify-db-password = {
    description = "Aligns the postgres role gotify password with the sops secret";
    wantedBy = ["multi-user.target"];
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    before = ["gotify-server.service"];
    requiredBy = ["gotify-server.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -v pw="$(cat ${config.sops.secrets."gotify/db_password".path})" <<'SQL'
      ALTER ROLE gotify WITH PASSWORD :'pw';
      SQL
    '';
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = ["gotify"];
    ensureUsers = [
      {
        name = "gotify";
        ensureDBOwnership = true;
      }
    ];
    # On tower the generic pg_hba let `host all all 127.0.0.1/32 trust`
    # pass BEFORE the gotify rule, hence this block in mkOverride 10 (higher
    # priority). On anywhere the pg_hba is already fully in trust on the
    # loopback and other databases live in the same cluster: applying
    # this list there would CLOSE the TCP access of pangolin/zabbix/vaultwarden. Hence
    # the option, disabled on the VPS.
    authentication = lib.mkIf config.services.gotify.managePostgresAuth (lib.mkOverride 10 ''
      # TYPE  DATABASE  USER     ADDRESS    METHOD
      host    gotify    gotify   127.0.0.1/32  md5
      local   all       all                 peer
    '');
  };

  # Exposure via Pangolin (newt blueprint) -> gotify.marcpartensky.com
  # NO Pangolin SSO: native clients (Android app, gotify-cli, the
  # scripts that push a notification to /message with an app token) do
  # not know how to follow a browser redirect, and this path IS Gotify's
  # main use case. Human login is ensured by the Zitadel OIDC
  # above (Gotify 3.x does it itself); the healthcheck on /health stays
  # reachable without auth, so the target will not drop out of the load-balancer.
  services.newt.blueprint.proxy-resources = lib.mkIf config.services.gotify.publishViaNewt {
    gotify = {
      name = "gotify";
      protocol = "http";
      full-domain = "gotify.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8070;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8070;
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
  };
}
