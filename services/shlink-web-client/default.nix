# services/shlink-web-client/default.nix
# Client web d'administration de Shlink (github.com/shlinkio/shlink-web-client)
# sur shlink.marcpartensky.com.
#
# Shlink lui-meme n'a AUCUNE UI (services/shlink n'expose que l'API REST sur
# s.marcpartensky.com) : ce conteneur sert la PWA React officielle. Tout part du
# NAVIGATEUR vers l'API (l'app est 100% client), donc le conteneur n'a besoin
# d'aucun acces reseau sortant et ne persiste rien : l'etat (serveurs, cle
# d'API) vit dans le localStorage du navigateur.
#
# SSO Pangolin ACTIF ici, contrairement a s.marcpartensky.com : un lien court
# doit resoudre pour n'importe qui, une console d'admin non. L'API Shlink est
# deja protegee par sa cle, ceci protege l'interface qui la manipule.
#
# Pas de paquet nixpkgs : conteneur OCI (nginx:alpine + build statique), meme
# pattern que services/aonsoku et services/chhoto.
#
# La cle d'API n'est VOLONTAIREMENT pas prerenseignee. SHLINK_SERVER_API_KEY
# ferait ecrire servers.json en clair dans la racine web servie par nginx, ce
# qui est exactement le "secret en clair" que le depot evite (et le README du
# projet met en garde dessus). Seule l'URL du serveur est pre-remplie : la cle
# se saisit une fois dans l'UI et reste dans le navigateur.
{
  config,
  lib,
  pkgs,
  ...
}: let
  port = 8100;
  domain = "shlink.marcpartensky.com";
in {
  # Conteneur sorti de la conf hote : deploy/containers.nix (entree
  # `shlink-web-client`, migrated = true), quadlet podman
  # `shlink-web-client.service`. Changer l'image ne demande plus ni eval ni
  # switch. Reprise : `just deploy shlink-web-client --takeover` AVANT le
  # switch qui retire ce bloc.
  #
  # Reste ici, et doit rester : la route newt/Pangolin ci-dessous.

  # Exposition publique : shlink.marcpartensky.com -> 127.0.0.1:8100, avec le
  # SSO Pangolin (Zitadel) comme les autres UIs.
  # NB : `auth.sso-enabled` gate la ressource, mais le blueprint ne porte pas de
  # champ pour aller directement a l'IdP : `resources.skipToIdpId = 1` est pose
  # en base Pangolin (comme pour navidrome et aonsoku), sinon la page de login
  # interne du proxy s'affiche avant Zitadel.
  services.newt.blueprint.proxy-resources.shlink-admin = {
    name = "shlink-admin";
    protocol = "http";
    full-domain = domain;
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
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

  # ── Garde-fous ─────────────────────────────────────────────────────────
  assertions = [
    {
      # Le port doit rester en loopback : l'UI n'a pas de mot de passe propre,
      # le seul rempart est le proxy (SSO) et donc l'absence d'exposition LAN.
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "shlink-web-client : le port ${toString port} ne doit pas etre ouvert au firewall (exposition uniquement via Pangolin/newt).";
    }
  ];
}