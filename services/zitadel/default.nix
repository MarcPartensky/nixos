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

    ensureDatabases = ["zitadel"];
    ensureUsers = [
      {
        name = "zitadel";
        ensureDBOwnership = true;
        ensureClauses.createrole = true;

      }
    ];
    enableTCPIP = true;
    authentication = lib.mkOverride 10 ''
      local   all         all         peer
      host    all         zitadel     127.0.0.1/32    trust
      host    all         zitadel     ::1/128         trust
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
      ExternalDomain = "auth.vps.marcpartensky.com";
      ExternalSecure = true;

      Machine = {
        Identification = {
          Hostname = {
            Enabled = true;
          };
          Webhook = {
            Enabled = false;
          };
        };
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
        Password = "motdepasse";
        PasswordChangeRequired = true;
        Email = {
          Address = "marc@marcpartensky.com";
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
