# services/matrix-telegram/default.nix
# Pont Matrix <-> Telegram (mautrix-telegram, bridge Python historique),
# serveur : ../matrix
#
# PAS ENCORE ACTIVÉ, volontairement : il manque api_id et api_hash, qui
# s'obtiennent uniquement avec un compte Telegram (https://my.telegram.org,
# section "API development tools", connexion avec son numéro de téléphone).
# api_id est un identifiant public, api_hash est le secret.
#
# Pour activer, trois choses :
#   1. renseigner api_id ci-dessous (nombre, pas un secret) ;
#   2. créer secrets/telegram.yml avec la clé telegram_api_hash (fichier neuf :
#      chiffrable avec les seules clés publiques de .sops.yaml) et ajouter la
#      creation_rule correspondante dans .sops.yaml ;
#   3. décommenter ./matrix-telegram dans services/default.nix.
{
  config,
  lib,
  ...
}: {
  sops.secrets.telegram_api_hash = {
    sopsFile = ../../secrets/telegram.yml;
    owner = "mautrix-telegram";
    mode = "0400";
    restartUnits = ["mautrix-telegram.service"];
  };

  # Le nix store ne contient que la référence $TELEGRAM_API_HASH, la valeur est
  # injectée par envsubst au démarrage (preStart du module), depuis ce fichier.
  sops.templates."matrix-telegram.env" = {
    content = ''
      TELEGRAM_API_HASH=${config.sops.placeholder.telegram_api_hash}
    '';
    owner = "mautrix-telegram";
    group = "mautrix-telegram";
    mode = "0400";
  };

  services.mautrix-telegram = {
    enable = true;

    environmentFile = config.sops.templates."matrix-telegram.env".path;

    settings = {
      homeserver = {
        address = "http://127.0.0.1:8008";
        domain = "matrix.marcpartensky.com";
      };
      appservice = {
        hostname = "127.0.0.1";
        # défaut du module : 8080, à éviter (déjà pris par jupyterhub sur tower)
        port = 29317;
      };
      bridge.permissions = {
        "matrix.marcpartensky.com" = "full";
        "@marc:matrix.marcpartensky.com" = "admin";
      };
      telegram = {
        # TODO: nombre récupéré sur my.telegram.org
        api_id = 0;
        api_hash = "$TELEGRAM_API_HASH";
      };
    };

    # La registration est générée dans le preStart du bridge, donc c'est synapse
    # qui doit l'attendre (cf. services/matrix), pas l'inverse.
    serviceDependencies = lib.mkForce [];
  };

  # Après déploiement, connexion (à faire par marc) : DM à
  # @telegrambot:matrix.marcpartensky.com, `login`, puis suivre les instructions
  # (numéro de téléphone, code reçu dans Telegram, mot de passe 2FA si activé).
}
