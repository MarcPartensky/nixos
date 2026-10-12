# services/hermes-files/default.nix
# Partage HTTP en lecture seule des artefacts produits par l'agent hermes
# (APK Hermes Pocket, exports, captures) sur le réseau local uniquement.
#
# hermes écrit dans /var/lib/hermes-files (son stateDir /var/lib/hermes est en
# 0770 : nginx ne peut pas le traverser, d'où un répertoire dédié en 0755).
# nginx le sert sur http://<ip-lan>:8092/ avec autoindex, sans authentification :
# ne rien y déposer de sensible, et ne jamais router ce port via Pangolin.
{...}: let
  port = 8092;
  root = "/var/lib/hermes-files";
in {
  systemd.tmpfiles.rules = [
    "d ${root} 0755 hermes hermes -"
  ];

  services.nginx.virtualHosts."hermes-files" = {
    # pas de serverName utile : seul vhost sur ce port, donc default_server de fait
    listen = [
      {
        addr = "0.0.0.0";
        inherit port;
      }
    ];
    inherit root;
    locations."/".extraConfig = ''
      autoindex on;
      # un .apk doit se télécharger, pas s'afficher
      types {
        application/vnd.android.package-archive apk;
      }
      default_type application/octet-stream;
    '';
  };

  networking.firewall.allowedTCPPorts = [port];
}
