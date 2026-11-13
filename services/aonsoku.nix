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
  # Le conteneur n'est plus declare ici : il est sorti de la conf hote dans
  # deploy/containers.nix (entree `aonsoku`, migrated = true) et tourne en
  # quadlet podman (`aonsoku.service`, fichier
  # /etc/containers/systemd/aonsoku.container pose par deploy/render.sh).
  # Changer l'image, le port ou une variable ne coute donc plus d'eval ni de
  # generation NixOS. Reprise (ordre documente dans deploy/containers.nix) :
  # `just deploy aonsoku --takeover` AVANT le switch qui retire ce bloc,
  # sinon le conteneur est supprime sans remplacant.
  #
  # Ce qui reste ici, et doit rester : la route newt/Pangolin ci-dessous.

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
