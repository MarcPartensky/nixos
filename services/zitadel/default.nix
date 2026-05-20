{
  pkgs,
  config,
  lib,
  ...
}: {
  sops.secrets = {
    "zitadel/db_password" = {
      owner = "zitadel";
      group = "zitadel";
      key = "zitadel_db_password";
    };
    "zitadel/admin_password" = {
      owner = "zitadel";
      group = "zitadel";
      key = "zitadel_admin_password";
    };
    "zitadel/master_key" = {
      owner = "zitadel";
      group = "zitadel";
      key = "zitadel_master_key";
    };
  };

  # ---------------------------------------------------------------------------
  # POSTGRESQL
  # ---------------------------------------------------------------------------
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    ensureDatabases = ["zitadel"];
    ensureUsers = [
      {
        name = "zitadel";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkOverride 10 ''
      local   zitadel     zitadel     peer
      local   all         all         peer
    '';
  };

  # ---------------------------------------------------------------------------
  # ZITADEL
  # ---------------------------------------------------------------------------
  services.zitadel = {
    enable = true;
    masterKeyFile = config.sops.secrets."zitadel/master_key".path;

    settings = {
      Port = 2080;
      ExternalPort = 443;
      ExternalDomain = "auth.marcpartensky.com";
      ExternalSecure = true;

      Database.postgres = {
        Host = "/run/postgresql";
        Database = "zitadel";
        User = {
          Username = "zitadel";
          SSL.Mode = "disable";
        };
        Admin = {
          Username = "zitadel";
          SSL.Mode = "disable";
        };
      };
    };

    steps.FirstInstance = {
      InstanceName = "Zitadel";
      Org.Human = {
        UserName = "admin";
        FirstName = "Admin";
        LastName = "User";
        DisplayName = "Administrator";
        PasswordChangeRequired = false;
        Email = {
          Address = "admin@marcpartensky.com";
          Verified = true;
        };
      };
    };
  };

  systemd.services.zitadel = {
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
  };
}
