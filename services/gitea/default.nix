# services/gitea/default.nix
# Instance Gitea (forge git auto-hébergée) sur git.marcpartensky.com.
#
# Écoute en loopback (127.0.0.1:3001), exposée uniquement via le blueprint
# Pangolin/newt (SSO devant, comme hermes-webui/hermes-dashboard). Base
# postgres locale via socket unix (peer auth, pas de secret DB nécessaire :
# services.gitea.database.createDatabase=true crée le rôle "gitea" et se
# connecte par défaut sur /run/postgresql avec le user système "gitea").
#
# Inscription publique désactivée (DISABLE_REGISTRATION) : le compte admin
# "marc" est créé une fois par un oneshot idempotent (gitea-admin-init) via
# la CLI, mot de passe dans secrets/gitea.yml (sops, clé admin_password).
#
# SSH désactivé pour ce premier déploiement (DISABLE_SSH) : le serveur SSH
# intégré de Gitea entrerait en conflit avec le sshd de tower, et newt 1.12.4
# ne supporte pas le mode de ressource "ssh" de Pangolin (exige > 1.13). Clone
# HTTPS uniquement pour l'instant (token d'accès personnel Gitea).
{
  config,
  lib,
  ...
}: {
  sops.secrets."gitea/admin_password" = {
    key = "admin_password";
    sopsFile = ../../secrets/gitea.yml;
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
        DISABLE_REGISTRATION = true;
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

  # Ressource publique Pangolin, appliquée par le site qui porte le blueprint
  # (tower) : `site` omis volontairement, cf. services/newt. Schéma
  # `proxy-resources` + `protocol` (celui vérifié fonctionnel côté hermes-webui
  # / hermes-dashboard sur ce contrôleur Pangolin, cf. selfhosted-remote-access
  # / references/pangolin-blueprint.md).
  services.newt.blueprint.proxy-resources.gitea = {
    name = "Gitea";
    protocol = "http";
    full-domain = "git.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = config.services.gitea.settings.server.HTTP_PORT;
        method = "http";
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
