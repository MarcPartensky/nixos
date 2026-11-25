# services/gitea/default.nix
# Gitea instance (self-hosted git forge) on git.marcpartensky.com.
#
# Listens on loopback (127.0.0.1:3001), exposed only via the
# Pangolin/newt blueprint, without Pangolin SSO (auth.sso-enabled=false): Gitea carries its
# own login (local accounts + Zitadel OIDC) and its API tokens - a single
# auth layer, and the git/API clients with a token are not redirected to an
# SSO page. Local postgres DB via unix socket (peer auth, no DB secret
# needed: services.gitea.database.createDatabase=true creates the "gitea" role
# and connects by default on /run/postgresql with the system user "gitea").
#
# Public registration disabled (DISABLE_REGISTRATION): the admin account
# "marc" is created once by an idempotent oneshot (gitea-admin-init) via
# the CLI, password in secrets/gitea.yml (sops, key admin_password).
#
# SSH disabled for this first deployment (DISABLE_SSH): Gitea's built-in
# SSH server would conflict with tower's sshd, and newt 1.12.4
# does not support Pangolin's "ssh" resource mode (requires > 1.13). Clone
# HTTPS only for now (Gitea personal access token).
#
# OIDC to Zitadel (auth.marcpartensky.com): OAuth2 auth source "Zitadel"
# (button on the login page), maintained by the gitea-oidc-init oneshot
# (idempotent, add-or-update). Zitadel app "Gitea" (marcpartensky project,
# appId 396570385799184684) of type Web: client_id below, client_secret
# in secrets/gitea-oidc.yml. NB: the [openid] section of app.ini is NOT
# OIDC (legacy OpenID 2.0, incompatible with Zitadel): disabled below.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # OIDC app "Gitea" in a DEDICATED ZITADEL PROJECT (project "Gitea", role
  # "gitea", projectRoleCheck): granting the role is what opens the app, and
  # this role opens NOTHING else. Zitadel GENERATES the client_id: "gitea"
  # (the old value) could never exist. The client_secret lives outside the
  # nix store (secrets/zitadel-oidc-secrets.yml, key gitea_client_secret).
  oidcClientId = "400636685496418604";
  oidcClientSecret = config.sops.secrets."gitea/oidc_client_secret";
in {
  sops.secrets."gitea/admin_password" = {
    key = "admin_password";
    sopsFile = ../../secrets/gitea.yml;
    owner = "gitea";
  };

  sops.secrets."gitea/oidc_client_secret" = {
    key = "gitea_client_secret";
    sopsFile = ../../secrets/zitadel-oidc-secrets.yml;
    owner = "gitea";
  };

  services.gitea = {
    enable = true;
    appName = "marc's Gitea";
    database.type = "postgres";
    settings = {
      server = {
        DOMAIN = "git.marcpartensky.com";
        ROOT_URL = "https://git.marcpartensky.com/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3001;
        DISABLE_SSH = true;
      };
      service = {
        DISABLE_REGISTRATION = false;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
        SHOW_REGISTRATION_BUTTON = false;
        # Closes anonymous access: exploration, raw, archives, anonymous API and
        # /compare pages require an account. Set on 15/11/2026 after measurement:
        # an AWS crawler (216.73.216.157) made 14 580 requests in 3 h on
        # /compare pages at 4 s of CPU each, i.e. 312 % of a core continuously.
        # Authenticated clients (git HTTPS with PAT, gitea MCP on
        # loopback, Zitadel OIDC) are not affected; anonymous clones and
        # navigation are, on purpose. The edge CIDR filtering
        # (DROP rules of Pangolin resource 32) remains the first layer.
        REQUIRE_SIGNIN_VIEW = true;
      };
      # Legacy OpenID 2.0 (the "OpenID" button of the login page): unrelated
      # to Zitadel which speaks OIDC. Disabled so as not to mislead
      # (with a Zitadel URL it fails with "LINK with
      # rel=openid2.provider not found"). The SSO goes through the OAuth2 source.
      openid = {
        ENABLE_OPENID_SIGNIN = false;
        ENABLE_OPENID_SIGNUP = false;
      };
      # OAuth2 source (Zitadel): automatic creation of the local account on
      # the first OIDC login. USERNAME=email -> localpart of the Zitadel email
      # (marc@marcpartensky.com -> "marc"). If the derived name collides
      # with an existing account (marc's case), ACCOUNT_LINKING=login shows
      # a linking page: you enter your local password once, then
      # the OIDC identity is attached to the existing account.
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        USERNAME = "email";
        ACCOUNT_LINKING = "login";
      };
      # Pangolin/newt tunnel locally: gitea would see every public
      # request as coming from 127.0.0.1. Nothing sensitive is protected
      # by an IP here (cf. jellyfin pitfall), but it avoids a misleading signal
      # in the gitea audit logs.
      security = {
        REVERSE_PROXY_TRUSTED_PROXIES = "127.0.0.1";
      };
    };
  };

  # Admin account created only once (idempotent: gitea silently refuses
  # to recreate an existing username, `|| true` swallows the error without making
  # the unit fail). Same environment as gitea.service (nixpkgs module).
  systemd.services.gitea-admin-init = {
    description = "Creates the Gitea admin account (idempotent)";
    after = ["gitea.service" "postgresql.service"];
    requires = ["gitea.service"];
    wantedBy = ["multi-user.target"];
    environment = {
      USER = config.services.gitea.user;
      HOME = config.services.gitea.stateDir;
      GITEA_WORK_DIR = config.services.gitea.stateDir;
      GITEA_CUSTOM = config.services.gitea.customDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = config.services.gitea.user;
      Group = config.services.gitea.group;
    };
    script = ''
      ${config.services.gitea.package}/bin/gitea admin user create \
        --username marc \
        --password "$(cat ${config.sops.secrets."gitea/admin_password".path})" \
        --email marc.partensky@proton.me \
        --admin --must-change-password=false || true
    '';
  };

  # Registers/updates the OAuth2 OIDC "Zitadel" source in Gitea
  # (idempotent add-or-update). Relies on the Zitadel app "Gitea":
  # client_id = oidcClientId, redirect_uri registered on the Zitadel side =
  # https://git.marcpartensky.com/user/oauth2/zitadel/callback.
  # The client_secret is read from sops at each run.
  # A change of client_id/secret on the Zitadel side only takes effect at
  # Gitea STARTUP: the gitea-oidc-init oneshot does write the DB, but the
  # server keeps the OAuth sources in memory (verified on 21/11/2026: after
  # migration to a dedicated Zitadel project, Gitea still served the OLD
  # client_id, hence a broken login, until the restart). This trigger forces the
  # restart at the activation that changes the value; the value being stable
  # afterwards, subsequent switches do not restart Gitea.
  systemd.services.gitea.restartTriggers = [oidcClientId];

  systemd.services.gitea-oidc-init = {
    description = "Registers the OAuth2 OIDC Zitadel source in Gitea (idempotent)";
    after = ["gitea.service" "gitea-admin-init.service" "postgresql.service"];
    requires = ["gitea.service" "gitea-admin-init.service"];
    wantedBy = ["multi-user.target"];
    environment = {
      USER = config.services.gitea.user;
      HOME = config.services.gitea.stateDir;
      GITEA_WORK_DIR = config.services.gitea.stateDir;
      GITEA_CUSTOM = config.services.gitea.customDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = config.services.gitea.user;
      Group = config.services.gitea.group;
    };
    script = ''
      set -eu
      DISCOVERY="https://auth.marcpartensky.com/.well-known/openid-configuration"
      SECRET="$(cat ${oidcClientSecret.path})"
      # Add-or-update: if the source exists (id in the DB), update it
      # (any drift of client_id/secret is corrected at each activation),
      # otherwise create it. In 1.27.x the sources created by the CLI are active
      # by default (the --enabled/--allow-deactivate flags no longer exist).
      PSQL="${config.services.postgresql.package}/bin/psql"
      SRC_ID="$("$PSQL" -U gitea -d gitea -Atc "select id from login_source where name = 'zitadel'")"
      if [ -n "$SRC_ID" ]; then
        ${config.services.gitea.package}/bin/gitea admin auth update-oauth \
          --id "$SRC_ID" \
          --key "${oidcClientId}" \
          --secret "$SECRET" \
          --auto-discover-url "$DISCOVERY" \
          --scopes openid --scopes email --scopes profile
      else
        ${config.services.gitea.package}/bin/gitea admin auth add-oauth \
          --name zitadel \
          --provider openidConnect \
          --key "${oidcClientId}" \
          --secret "$SECRET" \
          --auto-discover-url "$DISCOVERY" \
          --scopes openid --scopes email --scopes profile
      fi
    '';
  };

  # Pangolin public resource, applied by the site that carries the blueprint
  # (tower): `site` omitted on purpose, cf. services/newt. Schema
  # `proxy-resources` + `protocol` (the one verified working on the hermes-webui
  # / hermes-dashboard side on this Pangolin controller, cf. selfhosted-remote-access
  # / references/pangolin-blueprint.md). No Pangolin SSO: auth is
  # carried by Gitea itself (local + Zitadel OIDC), a single layer.
  services.newt.blueprint.proxy-resources.gitea = {
    name = "gitea";
    protocol = "http";
    full-domain = "git.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = config.services.gitea.settings.server.HTTP_PORT;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = config.services.gitea.settings.server.HTTP_PORT;
          path = "/api/healthz";
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

  # Safeguard: the local HTTP port must never be opened on the LAN.
  assertions = [
    {
      assertion = !(lib.elem config.services.gitea.settings.server.HTTP_PORT config.networking.firewall.allowedTCPPorts);
      message = "gitea: the local HTTP port must not be opened on the firewall (exposure only via Pangolin/newt).";
    }
  ];
}
