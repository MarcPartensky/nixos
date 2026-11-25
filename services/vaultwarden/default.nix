# services/vaultwarden/default.nix
{
  pkgs,
  config,
  lib,
  ...
}: {
  sops.secrets."vaultwarden/db_password" = {
    key = "vaultwarden_db_password";
    sopsFile = ../../secrets/common.yml;
    # read by vaultwarden-db-password.service, which runs as User=postgres
    # (vaultwarden itself reads the password via the sops template, not this file)
    owner = "postgres";
  };

  sops.secrets."vaultwarden/admin_token" = {
    key = "vaultwarden_admin_token";
    sopsFile = ../../secrets/common.yml;
  };

  sops.templates."vaultwarden.env" = {
    content = ''
      DATABASE_URL=postgres://vaultwarden:${config.sops.placeholder."vaultwarden/db_password"}@localhost:5432/vaultwarden
      ADMIN_TOKEN=${config.sops.placeholder."vaultwarden/admin_token"}
    '';
  };

  services.postgresql = {
    ensureDatabases = ["vaultwarden"];
    ensureUsers = [
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE     USER         ADDRESS        METHOD
      host    vaultwarden  vaultwarden  127.0.0.1/32   md5
      local   all          all                         peer
    '';
  };

  # Agent's TECHNICAL Vaultwarden vault (hermes@marcpartensky.com account).
  # Declared here so the secret is rendered on every activation, even when
  # services/vaultwarden-mcp is not imported yet. The password is
  # encrypted to tower's only age key (secrets/vaultwarden-agent.yml).
  #
  # NOT on anywhere: this file has only tower's key as recipient, and
  # sops-install-secrets fails BEFORE writing anything ("Error getting
  # data key: 0 successful groups required, got 0"), which aborts the WHOLE
  # activation. Yet the VPS vaultwarden instance does not need this secret
  # (it is the agent's vault, consumed from tower).
  sops.secrets."vaultwarden/agent_password" = lib.mkIf (config.networking.hostName != "anywhere") {
    key = "vaultwarden_agent_password";
    sopsFile = ../../secrets/vaultwarden-agent.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    environmentFile = config.sops.templates."vaultwarden.env".path;
    config = {
      DOMAIN = "https://vault.marcpartensky.com";
      # Closed since 10/11/2026: registration was open to the Internet
      # (/api/config answered disableUserRegistration:false and /identity
      # is not behind Pangolin SSO). The agent's technical account
      # (hermes@marcpartensky.com) and marc's now exist, so there is
      # no reason left to accept registrations. To create a
      # new one: set back to true, create, set back to false.
      SIGNUPS_ALLOWED = false;

      WEBSOCKET_ENABLED = true;
      WEBSOCKET_ADDRESS = "0.0.0.0";
      WEBSOCKET_PORT = 3012;

      ROCKET_ADDRESS = "0.0.0.0";
      # 8222 = vaultwarden default. Do NOT go back to 8083: that is the
      # nginx Nextcloud port (services/nextcloud/default.nix), and both on the same
      # port made vaultwarden crash in a loop (NRestarts climbing, rocket
      # cannot bind). Verified on 24/09/2026: vaultwarden was no longer
      # reachable since Nextcloud took 8083.
      ROCKET_PORT = 8222;
    };
  };

  # The vaultwarden postgres role was created without a password by ensureUsers,
  # while the effective pg_hba requires md5 for that role (services/postgresql.
  # authentication is a types.lines: ALL modules concatenate, and the
  # vaultwarden md5 rule comes before the generic "host all all 127.0.0.1/32 trust"
  # rule). Result verified in the journal on 24/09/2026:
  #   FATAL: password authentication failed for user "vaultwarden"
  # -> vaultwarden looped (retry ~30 s then exit 0, Restart=always).
  # Fix: align the role with the sops secret that DATABASE_URL already uses
  # (sops.templates."vaultwarden.env"). Idempotent, replayed on every activation.
  systemd.services.vaultwarden-db-password = {
    description = "Aligns the vaultwarden postgres role password with the sops secret";
    wantedBy = ["multi-user.target"];
    before = ["vaultwarden.service"];
    requiredBy = ["vaultwarden.service"];
    # postgresql.service is Type=notify: `after` guarantees the socket is ready.
    # Without these two lines the oneshot started in parallel with the postgres
    # startup and died on "connection to server on socket
    # "/run/postgresql/.s.PGSQL.5432" failed: No such file or directory"
    # (verified on the boots of 22/10 20:29 and 23/10 09:37).
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -v pw="$(cat ${config.sops.secrets."vaultwarden/db_password".path})" <<'SQL'
      ALTER ROLE vaultwarden WITH PASSWORD :'pw';
      SQL
    '';
  };

}
