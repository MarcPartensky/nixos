# services/gotify/default.nix
{
  pkgs,
  config,
  lib,
  inputs,
  ...
}: let
  # Gotify v3 (support OIDC natif) n'est pas dans la nixpkgs 26.05 épinglée
  # (2.9.1) : même convention que herdr/kanidm dans ce repo, on instancie
  # l'input unstable pour un paquet isolé.
  gotifyPkg = (import inputs.unstable { system = pkgs.stdenv.hostPlatform.system; }).gotify-server;
in {
  sops.secrets = {
    "gotify/admin_password" = {
      key = "gotify_admin_password";
    };
    "gotify/db_password" = {
      key = "gotify_db_password";
      # lu par gotify-db-password.service, qui tourne en User=postgres
      # (gotify lui-même lit le mot de passe via le template sops, pas ce fichier)
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
      # loopback uniquement : l'exposition passe par le tunnel newt/Pangolin.
      # Sans ce reglage le serveur bind [::]:8070 sur toutes les interfaces
      # (inoffensif tant que le port n'est pas dans networking.firewall.
      # allowedTCPPorts, mais une seule ligne oubliee suffirait a l'exposer).
      GOTIFY_SERVER_LISTENADDR = "127.0.0.1";
      GOTIFY_DATABASE_DIALECT = "postgres";
      GOTIFY_DEFAULTUSER_NAME = "admin";  # ne sert qu'à la création d'une base neuve (celle-ci existe déjà)
      GOTIFY_PASSSTRENGTH = "10";

      # OIDC / Zitadel SSO. PIEGE : Gotify 3.x nomme ses variables SANS
      # underscore entre les mots (gotify.net/docs/config) :
      #   GOTIFY_OIDC_CLIENTID, CLIENTSECRET, REDIRECTURL, USERNAMECLAIM.
      # Les formes snake_case (GOTIFY_OIDC_CLIENT_ID, ...) sont ignorées EN
      # SILENCE : l'UI afficherait le bouton SSO mais le flow échouerait.
      GOTIFY_OIDC_ENABLED = "true";
      # App OIDC PKCE (type User Agent, auth method None) créée dans Zitadel :
      # client_id 392663692992381228, redirect_uri enregistré en base Zitadel
      # (projections.apps7_oidc_configs) = https://gotify.marcpartensky.com/auth/oidc/callback
      GOTIFY_OIDC_CLIENTID = "392663692992381228";
      GOTIFY_OIDC_CLIENTSECRET = "";  # client public PKCE : aucun secret
      GOTIFY_OIDC_ISSUER = "https://auth.marcpartensky.com";
      GOTIFY_OIDC_REDIRECTURL = "https://gotify.marcpartensky.com/auth/oidc/callback";
      GOTIFY_OIDC_SCOPES = "openid,profile,email";  # "text-list" = séparateur VIRGULE, pas espace
      GOTIFY_OIDC_USERNAMECLAIM = "preferred_username";
      GOTIFY_OIDC_IDP_NAME = "Zitadel";
      GOTIFY_OIDC_AUTOREGISTER = "true";
      # Le user Zitadel de marc a pour username "marc@marcpartensky.com" (donc
      # preferred_username aussi) : il ne tombe PAS sur le compte local "marc".
      # Ce flag rattache l'identité OIDC au compte local de même nom au lieu
      # d'ouvrir un second compte. Le compte local a été renommé
      # "marc@marcpartensky.com" (UPDATE users : il porte les 4 applications et
      # les tokens clients déjà en place) tout en restant admin, car GroupsAdmin
      # est vide -> le flag admin existant est conservé.
      GOTIFY_OIDC_LINK_BY_USERNAME = "true";
    };

    environmentFiles = [
      config.sops.templates."gotify.env".path
    ];
  };

  # gotify dépend de postgres : sans ces réglages il crash-loopait quand un
  # switch redémarre postgresql (RestartSec=100ms par défaut, 5 essais, puis
  # start-limit-hit avant que postgres n'accepte de nouveau les connexions).
  #
  # Il dépend AUSSI du tunnel newt : au démarrage, Gotify 3.x fait un discovery
  # OIDC sur https://auth.marcpartensky.com (Zitadel est derrière Pangolin, donc
  # via newt) et sort en FTL « failed to initialize OIDC provider ... 503 » si le
  # tunnel n'est pas encore monté, ce qui tue le service. Vérifié le 09/10/2026 :
  # les 2 premières tentatives de démarrage ont échoué pour cette raison.
  # D'où after/wants newt + StartLimitIntervalSec = 0 (désactive le rate-limit
  # systemd) : le service retente indéfiniment au lieu de rester mort jusqu'au
  # prochain switch après 10 échecs en 60 s.
  systemd.services.gotify-server = {
    after = ["postgresql.service" "newt.service"];
    wants = ["postgresql.service" "newt.service"];
    unitConfig = {
      StartLimitIntervalSec = 0;
      StartLimitBurst = 10;
    };
    serviceConfig = {
      RestartSec = "5s";
    };
  };

  # MÊME BUG QUE VAULTWARDEN (vérifié 25/09/2026 en rejouant le binaire à la
  # main) : ensureUsers crée le rôle postgres `gotify` SANS mot de passe, alors
  # que le pg_hba effectif exige md5/scram pour ce rôle (services.postgresql.
  # authentication est un types.lines : tous les modules se concatènent et la
  # règle `host gotify gotify 127.0.0.1/32 md5` passe AVANT le
  # `host all all 127.0.0.1/32 trust` générique). Symptôme : gotify-server sort
  # en 64 ms avec status=2 et
  #   failed SASL auth: FATAL: password authentication failed for user "gotify"
  # puis start-limit-hit. Fix : aligner le rôle sur le secret sops déjà utilisé
  # par GOTIFY_DATABASE_CONNECTION. Idempotent, rejoué à chaque activation.
  systemd.services.gotify-db-password = {
    description = "Aligne le mot de passe du rôle postgres gotify sur le secret sops";
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
    authentication = lib.mkOverride 10 ''
      # TYPE  DATABASE  USER     ADDRESS    METHOD
      host    gotify    gotify   127.0.0.1/32  md5
      local   all       all                 peer
    '';
  };

  # Exposition via Pangolin (newt blueprint) -> gotify.marcpartensky.com
  # PAS de SSO Pangolin : les clients natifs (appli Android, gotify-cli, les
  # scripts qui poussent une notification sur /message avec un token d'app) ne
  # savent pas suivre une redirection navigateur, et ce chemin-la EST l'usage
  # principal de Gotify. Le login humain est assure par l'OIDC Zitadel
  # ci-dessus (Gotify 3.x le fait lui-meme) ; le healthcheck sur /health reste
  # joignable sans auth, donc la cible ne sortira pas du load-balancer.
  services.newt.blueprint.proxy-resources.gotify = {
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
}
