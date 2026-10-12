# services/matrix-whatsapp/default.nix
# Pont Matrix <-> WhatsApp (mautrix-whatsapp), serveur : ../matrix
{
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/mautrix-whatsapp";
in {
  # mautrix-whatsapp dépend de libolm (goolm) pour le chiffrement megolm,
  # marqué insecure dans nixpkgs (CVE-2024-4519x, side-channel théorique).
  # C'est la dépendance crypto standard de TOUS les bridges mautrix.
  nixpkgs.config.permittedInsecurePackages = ["olm-3.2.16"];

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:8008";
        domain = "matrix.marcpartensky.com";
      };
      appservice = {
        # bind localhost uniquement + URL de registration joignable par synapse
        hostname = "127.0.0.1";
        address = "http://127.0.0.1:29318";
        ephemeral_events = false;
      };
      bridge = {
        permissions = {
          # le défaut du module "*": "relay" est neutralisé par relay.enabled=false
          "matrix.marcpartensky.com" = "user";
          "@marc:matrix.marcpartensky.com" = "admin";
        };
        relay.enabled = false;
      };
      encryption = {
        allow = true;
        default = true;
        # require=false : ne pas dropper les messages si une room reste non chiffrée
        require = false;
        # $VAR substituée par envsubst dans le preStart du module (valeur exportée ci-dessous)
        pickle_key = "$MAUTRIX_WHATSAPP_PICKLE_KEY";
      };
      backfill.enabled = true;
      # base sqlite dans /var/lib/mautrix-whatsapp (défaut du module), suffisant ici
    };
    # Le module ajoute matrix-synapse.service aux deps par défaut ; on inverse
    # l'ordre : c'est synapse qui attend le bridge (cf. services/matrix),
    # car le bridge génère sa registration dans son preStart.
    serviceDependencies = lib.mkForce [];
  };

  # Pickle key e2ee générée une fois, hors du store nix.
  # mkBefore : exportée AVANT le envsubst du preStart du module qui l'injecte
  # dans config.yaml.
  systemd.services.mautrix-whatsapp.preStart = lib.mkBefore ''
    if [ ! -f ${dataDir}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dataDir}/pickle_key.txt
      chmod 600 ${dataDir}/pickle_key.txt
    fi
    export MAUTRIX_WHATSAPP_PICKLE_KEY=$(cat ${dataDir}/pickle_key.txt)
  '';

  # Le module enregistre tout seul le bridge auprès de synapse
  # (registerToSynapse = true quand synapse est activé) et donne à synapse
  # le groupe mautrix-whatsapp pour lire whatsapp-registration.yaml.

  # Après déploiement, connexion WhatsApp (à faire par marc, QR sur son tel) :
  #   1. ouvrir un DM avec @whatsappbot:matrix.marcpartensky.com dans son client Matrix
  #   2. envoyer : login
  #   3. scanner le QR code avec WhatsApp (appareils connectés)
}
