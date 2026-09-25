# services/matrix-meta/default.nix
# Ponts Matrix <-> Instagram et Matrix <-> Messenger (mautrix-meta : un même
# binaire sert les deux réseaux, une instance par réseau), serveur : ../matrix
{
  pkgs,
  lib,
  ...
}: let
  # Clé e2ee stable, hors du store nix. Le défaut du module est la constante
  # publique "mautrix.bridge.e2ee" : la DB crypto serait chiffrée avec une clé
  # connue de tous, donc on génère la nôtre au premier démarrage.
  mkPickleKey = instance: ''
    if [ ! -f /var/lib/mautrix-meta-${instance}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > /var/lib/mautrix-meta-${instance}/pickle_key.txt
      chmod 600 /var/lib/mautrix-meta-${instance}/pickle_key.txt
    fi
    export ENCRYPTION_PICKLE_KEY=$(cat /var/lib/mautrix-meta-${instance}/pickle_key.txt)
  '';

  homeserver = {
    address = "http://127.0.0.1:8008";
    domain = "matrix.marcpartensky.com";
  };

  permissions = {
    "matrix.marcpartensky.com" = "user";
    "@marc:matrix.marcpartensky.com" = "admin";
  };
in {
  services.mautrix-meta.instances = {
    # bot : @instagrambot:matrix.marcpartensky.com (port 29320 du preset)
    instagram = {
      enable = true;
      settings = {
        inherit homeserver;
        appservice.hostname = "127.0.0.1";
        bridge.permissions = permissions;
        encryption.pickle_key = "$ENCRYPTION_PICKLE_KEY";
      };
    };

    # bot : @messengerbot:matrix.marcpartensky.com
    # Le module n'a de preset que pour instagram et facebook, donc tout est
    # explicite ici (mode messenger = API de messenger.com).
    messenger = {
      enable = true;
      settings = {
        network.mode = "messenger";
        inherit homeserver;
        appservice = {
          id = "messenger";
          hostname = "127.0.0.1";
          port = 29322;
          bot = {
            username = "messengerbot";
            displayname = "Messenger bridge bot";
            avatar = "mxc://maunium.net/ygtkteZsXnGJLJHRchUwYWak";
          };
        };
        bridge.permissions = permissions;
        encryption.pickle_key = "$ENCRYPTION_PICKLE_KEY";
      };
    };
  };

  # Le envsubst qui écrit config.yaml vit dans l'unité de registration (pas dans
  # le preStart du bridge) : la clé doit être exportée DANS ce script, comme
  # pour matrix-discord.
  systemd.services = {
    mautrix-meta-instagram-registration.script = lib.mkBefore (mkPickleKey "instagram");
    mautrix-meta-messenger-registration.script = lib.mkBefore (mkPickleKey "messenger");
  };

  # Après déploiement, connexion (à faire par marc), une fois par réseau :
  #   1. DM au bot (@instagrambot ou @messengerbot)
  #   2. envoyer : login
  #   3. le bridge demande des cookies : se connecter normalement dans une
  #      fenêtre privée sur instagram.com ou messenger.com, devtools + onglet
  #      réseau + filtre XHR graphql, clic droit sur une requête, "Copy as cURL
  #      (POSIX)", et coller le tout dans le DM.
  #   Sinon, cookies utiles : Instagram sessionid, csrftoken, mid, ig_did,
  #   ds_user_id ; Facebook/Messenger datr, c_user, sb, xs.
  # Meta peut bloquer un compte jugé suspect (captcha / téléphone) : active la
  # double authentification pour limiter le risque.
}
