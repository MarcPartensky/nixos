{
  config,
  pkgs,
  lib,
  ...
}: {
  sops.secrets.newt_env = {
    sopsFile = ../../secrets/common.yml;
    mode = "0440";
  };

  services.newt = {
    enable = true;
    environmentFile = config.sops.secrets.newt_env.path;

    # Ressource publique Winnie : front (Dioxus UI, developpement local :8080).
    # Le domaine public sert le front ; le backend est deplace sur api.*.
    blueprint.proxy-resources.winnie-frontend = {
      name = "winnie-frontend";
      protocol = "http";
      full-domain = "winnie.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8080;
          method = "http";
        }
      ];
    };

    # Ressource publique Pangolin : le client noVNC de tower (wayvnc + websockify,
    # cf. modules/home/wayvnc). HTTP + SSO, donc aucune contrainte de version de
    # newt (le mode VNC natif de Pangolin exigerait newt > 1.13, et tower est en
    # 1.12.4 ; en HTTP la 1.12.4 suffit).
    #
    # Cible 127.0.0.1:6080 : newt tourne sur tower et résout la cible en local,
    # donc le service reste bindé sur loopback et rien n'est exposé sur le LAN.
    # `site` est omis volontairement : quand le blueprint est appliqué par un
    # site, Pangolin affecte automatiquement le site qui l'applique.
    # NB : le Pangolin de ce VPS (schema ancien) attend la cle `proxy-resources`
    # + le champ `protocol`. `public-resources`/`mode` (doc actuelle) sont
    # ignores SILENCIEUSEMENT par le serveur -> ressource jamais creee, et
    # Traefik repond 404 sur le domaine. Verifie le 26/09/2026.
    # Ressource publique Winnie (backend Rust/Axum, reverse proxy).
    blueprint.proxy-resources.winnie-backend = {
      name = "winnie-backend";
      protocol = "http";
      full-domain = "api.winnie.marcpartensky.com";
      auth.sso-enabled = false;  # l'app mobile ne peut pas suivre une redirection SSO
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8787;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = 8787;
            path = "/healthz";
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

    blueprint.proxy-resources.novnc-tower = {
      name = "vnc";
      protocol = "http";
      full-domain = "vnc.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 6080;
          method = "http";
          # noVNC sert son client sur /vnc.html : "/" repond 404 (mesure du
          # 28/09/2026), donc un healthcheck sur "/" marquerait la cible
          # unhealthy et Pangolin la sortirait du load-balancer.
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 6080;
          path = "/vnc.html";
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
  };

  # systemd.services.newt.serviceConfig = {
  #   DynamicUser = lib.mkForce false;
  #   PrivateUsers = lib.mkForce false;
  #   ProtectHome = lib.mkForce false;
  #   ExecStart = lib.mkForce (pkgs.writeShellScript "newt-start" ''
  #     set -a
  #     source ${config.sops.secrets.newt_env.path}
  #     set +a
  #     exec ${pkgs.fosrl-newt}/bin/newt \
  #       -endpoint="$PANGOLIN_ENDPOINT" \
  #       -id="$NEWT_ID" \
  #       -secret="$NEWT_SECRET"
  #   '');
  # };
}
