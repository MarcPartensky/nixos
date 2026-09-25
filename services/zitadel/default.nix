{
  pkgs,
  config,
  lib,
  ...
}: {
  sops.secrets = {
    # db_password supprimé : auth "trust" via socket, aucun mot de passe utilisé

    "zitadel/master_key" = {
      key = "zitadel_master_key";
      mode = "0440";
      group = "keys";
    };

    # Pour le mot de passe admin : le module NixOS n'a pas de stepsPasswordFile,
    # mais steps ne tourne qu'une seule fois (fresh install).
    # On l'exclut du nix store via un fichier steps séparé injecté par sops.
    "zitadel/steps" = {
      key = "zitadel_steps";
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

    # steps injecté via fichier sops plutôt qu'inline dans le nix store
    extraStepsPaths = [config.sops.secrets."zitadel/steps".path];

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
