# services/matrix-signal/default.nix
# Matrix <-> Signal bridge (mautrix-signal), server: ../matrix
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
      # The module default listens on "[::]": we stay on loopback.
      # settings has an `apply = recursiveUpdate defaultConfig`, so the other
      # default keys (port 29328, id "signal", bot signalbot) stay in
      # place.
      appservice.hostname = "127.0.0.1";
      bridge = {
        # neutralizes the module default's wildcard relay
        relay.enabled = false;
        permissions = {
          "matrix.marcpartensky.com" = "user";
          "@marc:matrix.marcpartensky.com" = "admin";
        };
      };
      # e2ee pickle key: stable value outside the nix store, cf. preStart.
      # allow/default true = portals encrypted by default (require=false to
      # not break a room that cannot be encrypted).
      encryption = {
        allow = true;
        default = true;
        require = false;
        pickle_key = "$ENCRYPTION_PICKLE_KEY";
      };
    };

    # The bridge generates its registration in ITS preStart: it is synapse that
    # must wait for it (cf. services/matrix), hence the neutralization of the
    # reverse dependency set by the module.
    serviceDependencies = lib.mkForce [];
  };

  # mkBefore: exported BEFORE the module preStart envsubst, which injects the
  # value into config.yaml.
  systemd.services.mautrix-signal.preStart = lib.mkBefore ''
    if [ ! -f ${dataDir}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dataDir}/pickle_key.txt
      chmod 600 ${dataDir}/pickle_key.txt
    fi
    export ENCRYPTION_PICKLE_KEY=$(cat ${dataDir}/pickle_key.txt)
  '';

  # After deployment, Signal connection (to be done by marc):
  #   1. open a DM with @signalbot:matrix.marcpartensky.com
  #   2. send: login
  #   3. Signal -> Settings -> Linked devices -> scan the QR code
  #   4. the bot confirms; `logout` to unlink the device
}
