# services/gitea/default.nix
# Instance Gitea (forge git auto-hébergée) sur git.marcpartensky.com.
#
# Écoute en loopback (127.0.0.1:3001), exposée uniquement via le blueprint
# Pangolin/newt, sans SSO Pangolin (auth.sso-enabled=false) : Gitea porte son
# propre login (comptes locaux + OIDC Zitadel) et ses tokens d'API — une seule
# couche d'auth, et les clients git/API à token ne sont pas redirigés vers une
# page SSO. Base postgres locale via socket unix (peer auth, pas de secret DB
# nécessaire : services.gitea.database.createDatabase=true crée le rôle "gitea"
# et se connecte par défaut sur /run/postgresql avec le user système "gitea").
#
# Inscription publique désactivée (DISABLE_REGISTRATION) : le compte admin
# "marc" est créé une fois par un oneshot idempotent (gitea-admin-init) via
# la CLI, mot de passe dans secrets/gitea.yml (sops, clé admin_password).
#
# SSH désactivé pour ce premier déploiement (DISABLE_SSH) : le serveur SSH
# intégré de Gitea entrerait en conflit avec le sshd de tower, et newt 1.12.4
# ne supporte pas le mode de ressource "ssh" de Pangolin (exige > 1.13). Clone
# HTTPS uniquement pour l'instant (token d'accès personnel Gitea).
#
# OIDC vers Zitadel (auth.marcpartensky.com) : source d'auth OAuth2 "Zitadel"
# (bouton sur la page de login), entretenue par le oneshot gitea-oidc-init
# (idempotent, add-or-update). App Zitadel "Gitea" (projet marcpartensky,
# appId 396570385799184684) de type Web : client_id ci-dessous, client_secret
# dans secrets/gitea-oidc.yml. NB : la section [openid] d'app.ini n'est PAS de
# l'OIDC (OpenID 2.0 legacy, incompatible avec Zitadel) : désactivée ci-dessous.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # App OIDC "Gitea" dans Zitadel (projet marcpartensky), créée le 24/10/2026.
  # Zitadel GÉNÈRE les client_id : "gitea" (l'ancienne valeur) n'a jamais pu
  # exister. Le client_secret vit hors du store nix (secrets/gitea-oidc.yml).
  oidcClientId = "396570385799250220";
  oidcClientSecret = config.sops.secrets."gitea/oidc_client_secret";
in {
  sops.secrets."gitea/admin_password" = {
    key = "admin_password";
    sopsFile = ../../secrets/gitea.yml;
    owner = "gitea";
  };

  sops.secrets."gitea/oidc_client_secret" = {
    key = "oidc_client_secret";
    sopsFile = ../../secrets/gitea-oidc.yml;
    owner = "gitea";
  };

  services.gitea = {
    enable = true;
    appName = "Gitea de marc";
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
      };
      # OpenID 2.0 legacy (bouton « OpenID » de la page de login) : sans
      # rapport avec Zitadel qui parle OIDC. Désactivé pour ne pas induire en
      # erreur (avec une URL Zitadel il échoue en "LINK with
      # rel=openid2.provider not found"). Le SSO passe par la source OAuth2.
      openid = {
        ENABLE_OPENID_SIGNIN = false;
        ENABLE_OPENID_SIGNUP = false;
      };
      # Source OAuth2 (Zitadel) : création automatique du compte local au
      # premier login OIDC. USERNAME=email → localpart de l'email Zitadel
      # (marc@marcpartensky.com → "marc"). Si le nom dérivé entre en collision
      # avec un compte existant (cas de marc), ACCOUNT_LINKING=login affiche
      # une page de liaison : on saisit son mot de passe local une fois, puis
      # l'identité OIDC est rattachée au compte existant.
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        USERNAME = "email";
        ACCOUNT_LINKING = "login";
      };
      # Pangolin/newt tunnelent en local : gitea verrait toute requête
      # publique comme venant de 127.0.0.1. Rien de sensible n'est protégé
      # par une IP ici (cf. piège jellyfin), mais ça évite un signal trompeur
      # dans les logs d'audit gitea.
      security = {
        REVERSE_PROXY_TRUSTED_PROXIES = "127.0.0.1";
      };
    };
  };

  # Compte admin créé une seule fois (idempotent : gitea refuse silencieusement
  # de recréer un username existant, `|| true` avale l'erreur sans faire
  # échouer l'unité). Même environnement que gitea.service (module nixpkgs).
  systemd.services.gitea-admin-init = {
    description = "Crée le compte admin Gitea (idempotent)";
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

  # Enregistre/actualise la source OAuth2 OIDC "Zitadel" dans Gitea
  # (add-or-update idempotent). S'appuie sur l'app Zitadel "Gitea" :
  # client_id = oidcClientId, redirect_uri enregistrée côté Zitadel =
  # https://git.marcpartensky.com/user/oauth2/zitadel/callback.
  # Le client_secret est lu depuis sops à chaque exécution.
  systemd.services.gitea-oidc-init = {
    description = "Enregistre la source OAuth2 OIDC Zitadel dans Gitea (idempotent)";
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
      # Add-or-update : si la source existe (id en base), la mettre à jour
      # (toute dérive de client_id/secret est corrigée à chaque activation),
      # sinon la créer. En 1.27.x les sources créées par la CLI sont actives
      # par défaut (les flags --enabled/--allow-deactivate n'existent plus).
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

  # Ressource publique Pangolin, appliquée par le site qui porte le blueprint
  # (tower) : `site` omis volontairement, cf. services/newt. Schéma
  # `proxy-resources` + `protocol` (celui vérifié fonctionnel côté hermes-webui
  # / hermes-dashboard sur ce contrôleur Pangolin, cf. selfhosted-remote-access
  # / references/pangolin-blueprint.md). Pas de SSO Pangolin : l'auth est
  # portée par Gitea lui-même (local + OIDC Zitadel), une seule couche.
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

  # Garde-fou : le port HTTP local ne doit jamais être ouvert sur le LAN.
  assertions = [
    {
      assertion = !(lib.elem config.services.gitea.settings.server.HTTP_PORT config.networking.firewall.allowedTCPPorts);
      message = "gitea : le port HTTP local ne doit pas être ouvert au firewall (exposition uniquement via Pangolin/newt).";
    }
  ];
}
