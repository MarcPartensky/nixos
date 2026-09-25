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

    # Ressource publique Pangolin : le client noVNC de tower (wayvnc + websockify,
    # cf. modules/home/wayvnc). HTTP + SSO, donc aucune contrainte de version de
    # newt (le mode VNC natif de Pangolin exigerait newt > 1.13, et tower est en
    # 1.12.4 ; en HTTP la 1.12.4 suffit).
    #
    # Cible 127.0.0.1:6080 : newt tourne sur tower et résout la cible en local,
    # donc le service reste bindé sur loopback et rien n'est exposé sur le LAN.
    # `site` est omis volontairement : quand le blueprint est appliqué par un
    # site, Pangolin affecte automatiquement le site qui l'applique.
    blueprint.public-resources.novnc-tower = {
      name = "noVNC tower";
      mode = "http";
      full-domain = "vnc.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 6080;
          method = "http";
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
