# services/matrix-signal/default.nix
# Pont Matrix <-> Signal (mautrix-signal), serveur : ../matrix
{
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/mautrix-signal";
in {
  services.mautrix-signal = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:8008";
        domain = "matrix.marcpartensky.com";
      };
      # Le défaut du module écoute sur "[::]" : on reste sur loopback.
      # settings a un `apply = recursiveUpdate defaultConfig`, donc les autres
      # clés du défaut (port 29328, id "signal", bot signalbot) restent en
      # place.
      appservice.hostname = "127.0.0.1";
      bridge = {
        # neutralise le wildcard relay du défaut du module
        relay.enabled = false;
        permissions = {
          "matrix.marcpartensky.com" = "user";
          "@marc:matrix.marcpartensky.com" = "admin";
        };
      };
      # pickle key e2ee : valeur stable hors du store nix, cf. preStart.
      # allow/default à true = portails chiffrés par défaut (require=false pour
      # ne pas casser une salle non chiffrable).
      encryption = {
        allow = true;
        default = true;
        require = false;
        pickle_key = "$ENCRYPTION_PICKLE_KEY";
      };
    };

    # Le bridge génère sa registration dans SON preStart : c'est synapse qui
    # doit l'attendre (cf. services/matrix), d'où la neutralisation de la
    # dépendance inverse posée par le module.
    serviceDependencies = lib.mkForce [];
  };

  # mkBefore : exporté AVANT le envsubst du preStart du module, qui injecte la
  # valeur dans config.yaml.
  systemd.services.mautrix-signal.preStart = lib.mkBefore ''
    if [ ! -f ${dataDir}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dataDir}/pickle_key.txt
      chmod 600 ${dataDir}/pickle_key.txt
    fi
    export ENCRYPTION_PICKLE_KEY=$(cat ${dataDir}/pickle_key.txt)
  '';

  # Après déploiement, connexion Signal (à faire par marc) :
  #   1. ouvrir un DM avec @signalbot:matrix.marcpartensky.com
  #   2. envoyer : login
  #   3. Signal -> Réglages -> Appareils liés -> scanner le QR code
  #   4. le bot confirme ; `logout` pour détacher l'appareil
}
