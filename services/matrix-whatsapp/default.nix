# services/matrix-whatsapp/default.nix
# Matrix <-> WhatsApp bridge (mautrix-whatsapp), server: ../matrix
{
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/mautrix-whatsapp";
in {
  # mautrix-whatsapp depends on libolm (goolm) for megolm encryption,
  # marked insecure in nixpkgs (CVE-2024-4519x, theoretical side-channel).
  # It is the standard crypto dependency of ALL mautrix bridges.
  nixpkgs.config.permittedInsecurePackages = ["olm-3.2.16"];

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:8008";
        domain = "matrix.marcpartensky.com";
      };
      appservice = {
        # bind localhost only + registration URL reachable by synapse
        hostname = "127.0.0.1";
        address = "http://127.0.0.1:29318";
        ephemeral_events = false;
      };
      bridge = {
        permissions = {
          # the module default "*": "relay" is neutralized by relay.enabled=false
          "matrix.marcpartensky.com" = "user";
          "@marc:matrix.marcpartensky.com" = "admin";
        };
        relay.enabled = false;
      };
      encryption = {
        allow = true;
        default = true;
        # require=false: do not drop messages if a room stays unencrypted
        require = false;
        # $VAR substituted by envsubst in the module preStart (value exported below)
        pickle_key = "$MAUTRIX_WHATSAPP_PICKLE_KEY";
      };
      backfill.enabled = true;
      # sqlite database in /var/lib/mautrix-whatsapp (module default), sufficient here
    };
    # The module adds matrix-synapse.service to the deps by default; we reverse
    # the order: it is synapse that waits for the bridge (cf. services/matrix),
    # because the bridge generates its registration in its preStart.
    serviceDependencies = lib.mkForce [];
  };

  # e2ee pickle key generated once, outside the nix store.
  # mkBefore: exported BEFORE the envsubst of the module preStart that injects it
  # into config.yaml.
  systemd.services.mautrix-whatsapp.preStart = lib.mkBefore ''
    if [ ! -f ${dataDir}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dataDir}/pickle_key.txt
      chmod 600 ${dataDir}/pickle_key.txt
    fi
    export MAUTRIX_WHATSAPP_PICKLE_KEY=$(cat ${dataDir}/pickle_key.txt)
  '';

  # The module registers the bridge with synapse on its own
  # (registerToSynapse = true when synapse is enabled) and gives synapse
  # the mautrix-whatsapp group to read whatsapp-registration.yaml.

  # After deployment, WhatsApp login (to be done by marc, QR on his phone):
  #   1. open a DM with @whatsappbot:matrix.marcpartensky.com in his Matrix client
  #   2. send: login
  #   3. scan the QR code with WhatsApp (linked devices)
}
