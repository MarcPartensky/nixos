# services/reactive-resume/default.nix
# Reactive Resume (github.com/AmruthPillai/Reactive-Resume) sur cv.marcpartensky.com.
#
# Inspiré du docker-compose perso de marc (github.com/marcpartensky/docker,
# services/resume/compose.yml), mais simplifié pour la version actuelle de
# l'image (>= v5.1) : depuis v5.1 le PDF est généré côté navigateur
# (@react-pdf/renderer), donc plus de conteneur "printer" (browserless/chrome)
# ni de PRINTER_*/BROWSERLESS_*. Le stockage S3 (Minio dans l'ancien setup) est
# optionnel depuis la même version : si les S3_* sont vides l'app stocke les
# uploads en local (/app/data) — on garde ça pour éviter de déployer Minio.
#
# Pas de paquet nixpkgs pour cette app (Node/NestJS) : conteneur OCI via podman
# (virtualisation.oci-containers, cf. services/chhoto pour le même pattern).
# --network=host (au lieu d'un port mappé) car l'app doit parler à Postgres en
# 127.0.0.1:5432 comme un service natif — même convention loopback que le
# reste de tower, le firewall reste fermé sur ce port (assertion en bas).
{
  config,
  lib,
  pkgs,
  ...
}: {
  sops.secrets."reactive-resume/db_password" = {
    key = "reactive_resume_db_password";
    sopsFile = ../../secrets/reactive-resume.yml;
    # lu par reactive-resume-db-password.service (User=postgres) ; l'app elle
    # même lit le mot de passe via le template sops ci-dessous, pas ce fichier.
    owner = "postgres";
  };

  sops.secrets."reactive-resume/auth_secret" = {
    key = "reactive_resume_auth_secret";
    sopsFile = ../../secrets/reactive-resume.yml;
  };

  sops.templates."reactive-resume.env" = {
    content = ''
      TZ=America/New_York
      APP_URL=https://cv.marcpartensky.com
      PORT=8098
      DATABASE_URL=postgresql://reactive-resume:${config.sops.placeholder."reactive-resume/db_password"}@127.0.0.1:5432/reactive-resume
      AUTH_SECRET=${config.sops.placeholder."reactive-resume/auth_secret"}
      # Inscription ouverte pour l'instant : le point d'entrée est de toute
      # façon derrière le SSO Pangolin (auth.sso-enabled ci-dessous). Repasser
      # à true une fois le compte de marc créé si on veut fermer les inscriptions.
      FLAG_DISABLE_SIGNUPS=false
    '';
  };

  services.postgresql = {
    ensureDatabases = ["reactive-resume"];
    ensureUsers = [
      {
        name = "reactive-resume";
        ensureDBOwnership = true;
      }
    ];
    # types.lines : se concatène avec les règles des autres modules (postgres,
    # vaultwarden, gitea...) au lieu de les remplacer. Même mkOverride 10 que
    # vaultwarden, pattern vérifié fonctionnel (cf skill marc-nixos-config).
    authentication = lib.mkOverride 10 ''
      host    reactive-resume  reactive-resume  127.0.0.1/32   md5
    '';
  };

  # Aligne le mot de passe du rôle postgres sur le secret sops utilisé par
  # DATABASE_URL (ensureUsers ne pose pas de mot de passe). Même pattern que
  # vaultwarden-db-password.
  systemd.services.reactive-resume-db-password = {
    description = "Aligne le mot de passe du rôle postgres reactive-resume sur le secret sops";
    wantedBy = ["multi-user.target"];
    before = ["podman-reactive-resume.service"];
    requiredBy = ["podman-reactive-resume.service"];
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql \
        -v pw="$(cat ${config.sops.secrets."reactive-resume/db_password".path})" <<'SQL'
      ALTER ROLE "reactive-resume" WITH PASSWORD :'pw';
      SQL
    '';
  };

  # Uploads locaux (pas de S3/Minio). uid/gid 1000 = user "node" de l'image
  # officielle amruthpillai/reactive-resume.
  systemd.tmpfiles.rules = [
    "d /var/lib/reactive-resume 0750 1000 1000 -"
    "d /var/lib/reactive-resume/data 0750 1000 1000 -"
  ];

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.reactive-resume = {
    image = "docker.io/amruthpillai/reactive-resume:v5.2";
    autoStart = true;
    volumes = ["/var/lib/reactive-resume/data:/app/data"];
    environmentFiles = [config.sops.templates."reactive-resume.env".path];
    extraOptions = [
      "--network=host"
      "--pull=newer"
      "--health-cmd=node -e \"fetch('http://127.0.0.1:8098/api/health').then((r) => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1));\""
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
    ];
  };

  systemd.services."podman-reactive-resume" = {
    after = ["network-online.target" "postgresql.service" "reactive-resume-db-password.service"];
    wants = ["network-online.target"];
    requires = ["reactive-resume-db-password.service"];
  };

  # Ressource publique Pangolin : schéma `proxy-resources` + `protocol`
  # (celui qui marche réellement sur ce contrôleur, cf gitea/jellyfin).
  # SSO activé : ferme l'accès (y compris inscription) derrière Zitadel.
  services.newt.blueprint.proxy-resources.reactive-resume = {
    name = "reactive-resume";
    protocol = "http";
    full-domain = "cv.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8098;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8098;
          path = "/api/health";
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

  # Garde-fou : jamais de port ouvert au LAN (--network=host expose 8098 sur
  # toutes les interfaces du host, seul le firewall protège du LAN direct).
  assertions = [
    {
      assertion = !(lib.elem 8098 config.networking.firewall.allowedTCPPorts);
      message = "reactive-resume : le port 8098 ne doit pas être ouvert au firewall (exposition uniquement via Pangolin/newt).";
    }
  ];
}
