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

    # Mot de passe du compte d'envoi noreply@marcpartensky.com (Stalwart sur le
    # VPS). Fichier dédié pour que hermes puisse l'écrire sans toucher au reste.
    "zitadel/smtp_password" = {
      sopsFile = ../../secrets/zitadel-smtp.yml;
      key = "zitadel_smtp_password";
    };

    # "zitadel/steps" retiré le 12/10/2026 : le secret pointait sur
    # zitadel_steps, chiffré en type:int dans secrets/anywhere.yml, ce que
    # sops-install-secrets refuse ("the value of key '' is not a string"). Il
    # faisait donc échouer tout le setupSecrets du VPS, donc l'activation
    # entière : aucun secret n'était écrit (master key absente, zitadel en
    # boucle de crash) et le switch retournait en erreur.
    #
    # Un steps YAML ne sert qu'à la première initialisation d'une instance, or
    # celle-ci est déjà initialisée (base "zitadel" existante). Pour repartir
    # d'une instance neuve : chiffrer le YAML des steps en type:str et remettre
    # extraStepsPaths = [ config.sops.secrets."zitadel/steps".path ].
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

    # Pas de clé SMTP ici : depuis ZITADEL v2 la config SMTP vit dans la base
    # (projection smtp_configs) et se modifie par l'API admin
    # POST /admin/v1/smtp ou la console. Le fichier de config runtime l'ignore
    # (vérifié le 19/10/2026 : SMTP.* dans --config ne produit que
    # Errors.SMTPConfig.NotFound). Le mot de passe du compte d'envoi est dans
    # secrets/zitadel-smtp.yml pour la provisioning par API.

    # extraStepsPaths retiré : voir le commentaire sur sops.secrets ci-dessus.

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
