# services/aonsoku/default.nix
# Aonsoku (github.com/victoralvesf/aonsoku) sur music.marcpartensky.com.
#
# Client web moderne pour Navidrome/Subsonic (React, MIT) : c'est une SPA
# servie par nginx dans l'image ; tout l'appel musical part du NAVIGATEUR vers
# SERVER_URL, donc le conteneur n'a besoin d'aucun acces reseau sortant vers
# Navidrome, et aucune donnee n'est persistee (etat en localStorage).
#
# Pourquoi ca marche alors que Navidrome est derriere le SSO Pangolin :
# Aonsoku parle a https://navidrome.marcpartensky.com/rest/*, et ces chemins
# sont sortis du gate par des regles ACCEPT cote Pangolin (cf.
# services/navidrome). Les identifiants Subsonic (user + mot de passe) sont
# saisis dans le navigateur, pas stockes en nix.
#
# Pas de paquet nixpkgs : conteneur OCI via podman
# (virtualisation.oci-containers, meme pattern que services/chhoto et
# services/reactive-resume).
{
  config,
  lib,
  pkgs,
  ...
}: {
  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.aonsoku = {
    image = "ghcr.io/victoralvesf/aonsoku:latest";
    autoStart = true;
    # Port publie sur la loopback uniquement : seul newt joint l'app, rien
    # n'est ouvert au LAN (pas de port dans networking.firewall).
    extraOptions = [
      "--publish=127.0.0.1:8099:8080"
      "--pull=newer"
      "--health-cmd=wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1"
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
    ];
    environment = {
      # Serveur Subsonic prerenseigne et champ serveur masque : il ne reste
      # que user + mot de passe a saisir.
      SERVER_URL = "https://navidrome.marcpartensky.com";
      HIDE_SERVER = "true";
      SERVER_TYPE = "navidrome";
      # Theme par defaut de marc ; APP_HIDE_THEMES reste false pour qu'il
      # puisse changer dans l'UI.
      APP_THEME = "catppuccin-mocha";
      # Pas d'auto-login : APP_USER/APP_PASSWORD exigeraient le mot de passe
      # en clair dans le store nix. A saisir une fois, le navigateur le garde.
    };
  };

  # Exposition publique : music.marcpartensky.com -> 127.0.0.1:8099, avec le
  # SSO Pangolin (Zitadel) comme les autres UIs.
  # NB : `auth.sso-enabled` gate la ressource, mais le blueprint ne porte pas de
  # champ pour aller directement a l'IdP : `resources.skipToIdpId = 1` est pose
  # en base Pangolin (comme pour navidrome), sinon la page de login interne du
  # proxy s'affiche avant Zitadel. A reposer si la ressource est recreee (uuid
  # qui change).
  services.newt.blueprint.proxy-resources.aonsoku = {
    name = "aonsoku";
    protocol = "http";
    full-domain = "music.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8099;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8099;
          path = "/";
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
