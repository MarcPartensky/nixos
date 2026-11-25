{
  pkgs,
  config,
  lib,
  ...
}: {
  sops.secrets = {
    # db_password removed: "trust" auth via socket, no password used

    "zitadel/master_key" = {
      key = "zitadel_master_key";
      mode = "0440";
      group = "keys";
    };

    # "zitadel/steps" removed on 12/10/2026: the secret pointed to
    # zitadel_steps, encrypted as type:int in secrets/anywhere.yml, which
    # sops-install-secrets rejects ("the value of key '' is not a string"). It
    # therefore made the whole VPS setupSecrets fail, hence the whole
    # activation: no secret was written (master key missing, zitadel in a
    # crash loop) and the switch returned an error.
    #
    # A steps YAML is only used for the first initialization of an instance, and
    # this one is already initialized ("zitadel" database exists). To start over
    # from a fresh instance: encrypt the steps YAML as type:str and restore
    # extraStepsPaths = [ config.sops.secrets."zitadel/steps".path ].
  } // lib.optionalAttrs (config.networking.hostName != "anywhere") {
    # Password of the sending account noreply@marcpartensky.com (Stalwart on the
    # VPS). Dedicated file so that hermes can write it without touching the rest.
    # OUTSIDE anywhere: secrets/zitadel-smtp.yml does not have the VPS age key, and a
    # single undecryptable file aborts ALL of setupSecrets (hence the activation).
    # This secret is only used for PROVISIONING via API - the SMTP config lives in
    # the Zitadel database (smtp_configs projection) - so its absence on the VPS
    # changes nothing at runtime.
    "zitadel/smtp_password" = {
      sopsFile = ../../secrets/zitadel-smtp.yml;
      key = "zitadel_smtp_password";
    };
  };

  users.users.zitadel.extraGroups = ["keys"];

  services.postgresql = {
    ensureDatabases = ["zitadel"];
    ensureUsers = [
      {
        name = "zitadel";
        ensureDBOwnership = true;
        ensureClauses.createrole = true;
        ensureClauses.createdb = true;
      }
    ];
    enableTCPIP = true;
    authentication = lib.mkOverride 10 ''
      local   all         all         peer
      host    all         zitadel     127.0.0.1/32    trust
      host    all         zitadel     ::1/128         trust
    '';
  };

  services.zitadel = {
    enable = true;
    masterKeyFile = config.sops.secrets."zitadel/master_key".path;

    # No SMTP key here: since ZITADEL v2 the SMTP config lives in the database
    # (smtp_configs projection) and is modified via the admin API
    # POST /admin/v1/smtp or the console. The runtime config file ignores it
    # (checked on 19/10/2026: SMTP.* in --config only produces
    # Errors.SMTPConfig.NotFound). The sending account password is in
    # secrets/zitadel-smtp.yml for API provisioning.

    # extraStepsPaths removed: see the comment on sops.secrets above.

    settings = {
      Port = 2080;
      ExternalPort = 443;
      ExternalDomain = "auth.marcpartensky.com";
      ExternalSecure = true;
      Machine.Identification = {
        Hostname.Enabled = true;
        Webhook.Enabled = false;
      };
      Database.postgres = {
        Host = "127.0.0.1";
        Port = 5432;
        Database = "zitadel";
        User = {
          Username = "zitadel";
          SSL.Mode = "disable";
        };
        Admin = {
          Username = "postgres";
          SSL.Mode = "disable";
        };
      };
    };
  };

  systemd.services.zitadel = {
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
  };
}
