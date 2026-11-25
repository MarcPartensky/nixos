# services/matrix-telegram/default.nix
# Matrix <-> Telegram bridge (mautrix-telegram, historical Python bridge),
# server: ../matrix
#
# NOT YET ENABLED, on purpose: api_id and api_hash are missing, which
# are obtained only with a Telegram account (https://my.telegram.org,
# section "API development tools", login with your phone number).
# api_id is a public identifier, api_hash is the secret.
#
# To enable, three things:
#   1. fill in api_id below (number, not a secret);
#   2. create secrets/telegram.yml with the telegram_api_hash key (new file:
#      encryptable with the sole public keys of .sops.yaml) and add the
#      corresponding creation_rule in .sops.yaml;
#   3. uncomment ./matrix-telegram in services/default.nix.
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

  # The nix store contains only the $TELEGRAM_API_HASH reference, the value is
  # injected by envsubst at startup (module preStart), from this file.
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
        # module default: 8080, to avoid (already taken by jupyterhub on tower)
        port = 29317;
      };
      bridge.permissions = {
        "matrix.marcpartensky.com" = "full";
        "@marc:matrix.marcpartensky.com" = "admin";
      };
      telegram = {
        # TODO: number retrieved from my.telegram.org
        api_id = 0;
        api_hash = "$TELEGRAM_API_HASH";
      };
    };

    # The registration is generated in the bridge preStart, so it is synapse
    # that must wait for it (cf. services/matrix), not the opposite.
    serviceDependencies = lib.mkForce [];
  };

  # After deployment, login (to be done by marc): DM to
  # @telegrambot:matrix.marcpartensky.com, `login`, then follow the instructions
  # (phone number, code received in Telegram, 2FA password if enabled).
}
