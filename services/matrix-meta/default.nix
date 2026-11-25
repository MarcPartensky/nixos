# services/matrix-meta/default.nix
# Matrix <-> Instagram and Matrix <-> Messenger bridges (mautrix-meta: a single
# binary serves both networks, one instance per network), server: ../matrix
{
  pkgs,
  lib,
  ...
}: let
  # Stable e2ee key, outside the nix store. The module default is the public
  # constant "mautrix.bridge.e2ee": the crypto DB would be encrypted with a key
  # known to everyone, so we generate our own on first startup.
  mkPickleKey = instance: ''
    if [ ! -f /var/lib/mautrix-meta-${instance}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > /var/lib/mautrix-meta-${instance}/pickle_key.txt
      chmod 600 /var/lib/mautrix-meta-${instance}/pickle_key.txt
    fi
    export ENCRYPTION_PICKLE_KEY=$(cat /var/lib/mautrix-meta-${instance}/pickle_key.txt)
  '';

  # A STABLE as_token/hs_token, SPECIFIC TO EACH instance, outside the nix
  # store, same pattern as pickle_key.txt. Without these files the registration
  # unit rewrites on each run a config.yaml WITHOUT tokens (the store template
  # has none) and the two instances end up sharing the same as_token: Synapse
  # then refuses to start ("Cannot reuse as_token across application
  # services") and the WHOLE homeserver falls, hence all the bridges. Experienced on
  # 24/11/2026 after the 17h37 reboot: this block had disappeared from the repo while
  # the .txt generated on 03/11 are still on disk.
  mkTokens = instance: let
    dir = "/var/lib/mautrix-meta-${instance}";
    prefix = "META_${lib.toUpper instance}";
  in ''
    for kind in as_token hs_token; do
      if [ ! -s ${dir}/$kind.txt ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dir}/$kind.txt
        chmod 600 ${dir}/$kind.txt
      fi
    done
    export ${prefix}_AS_TOKEN=$(cat ${dir}/as_token.txt)
    export ${prefix}_HS_TOKEN=$(cat ${dir}/hs_token.txt)
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
    # bot: @instagrambot:matrix.marcpartensky.com (port 29320 of the preset)
    instagram = {
      enable = true;
      settings = {
        inherit homeserver;
        appservice = {
          hostname = "127.0.0.1";
          # Literals: envsubst replaces them with the values of the files
          # /var/lib/mautrix-meta-instagram/{as,hs}_token.txt (cf. mkTokens).
          as_token = "$META_INSTAGRAM_AS_TOKEN";
          hs_token = "$META_INSTAGRAM_HS_TOKEN";
        };
        bridge.permissions = permissions;
        encryption.pickle_key = "$ENCRYPTION_PICKLE_KEY";
        # The module default (cross-signed-tofu) requires cross-signing
        # signatures: any message coming from a non cross-signed device is
        # refused ("your message was not bridged: your device is not trusted"),
        # so an agent device (HERMESMARC01, never verified by marc) can
        # neither drive the bot nor launch 'login'. The upstream mautrix-meta
        # already uses 'unverified' by default.
        encryption.verification_levels.receive = "unverified";
        encryption.verification_levels.send = "unverified";
        # 'share' governs the megolm keys that the bridge agrees to give to a
        # device: left at cross-signed-tofu, it shares nothing with
        # HERMESMARC01, so the agent CANNOT read the messages of the bridges
        # (marcmsg read returns SessionNotFound). The upstream already sets
        # 'cross-signed-tofu' here; we lower it just like send.
        encryption.verification_levels.share = "unverified";
      };
    };

    # bot: @messengerbot:matrix.marcpartensky.com
    # The module has a preset only for instagram and facebook, so everything is
    # explicit here (messenger mode = messenger.com API).
    messenger = {
      enable = true;
      settings = {
        network.mode = "messenger";
        inherit homeserver;
        appservice = {
          id = "messenger";
          hostname = "127.0.0.1";
          port = 29322;
          # Literals: envsubst replaces them with the files
          # /var/lib/mautrix-meta-messenger/{as,hs}_token.txt (cf. mkTokens).
          # Without them the two meta instances share the same as_token and
          # Synapse refuses to start ("Cannot reuse as_token").
          as_token = "$META_MESSENGER_AS_TOKEN";
          hs_token = "$META_MESSENGER_HS_TOKEN";
          bot = {
            username = "messengerbot";
            displayname = "Messenger bridge bot";
            avatar = "mxc://maunium.net/ygtkteZsXnGJLJHRchUwYWak";
          };
        };
        bridge.permissions = permissions;
        encryption.pickle_key = "$ENCRYPTION_PICKLE_KEY";
        # Backfill disabled by default in this build: the portals are created
        # EMPTY (0 message), only new conversations arrive. On a
        # standard Matrix server (not Beeper) the backfill can fill
        # only a new room: the "backwards" queue of the doc does not apply.
        backfill.enabled = true;
        backfill.max_initial_messages = 200;
        backfill.threads.max_initial_messages = 200;
        # Cf. instagram above: necessary so that the agent can send
        # 'login messenger' from HERMESMARC01 and read the bot's replies.
        encryption.verification_levels.receive = "unverified";
        encryption.verification_levels.send = "unverified";
        encryption.verification_levels.share = "unverified";
      };
    };
  };

  # The envsubst that writes config.yaml lives in the registration unit (not in
  # the bridge's preStart): the key must be exported INSIDE that script, as
  # for matrix-discord.
  systemd.services = {
    mautrix-meta-instagram-registration.script = lib.mkBefore (
      mkPickleKey "instagram" + mkTokens "instagram"
    );
    mautrix-meta-messenger-registration.script = lib.mkBefore (
      mkPickleKey "messenger" + mkTokens "messenger"
    );

    # The bridge re-reads its config only at startup: without these triggers a
    # config change (e.g. verification_levels) is never active after a
    # switch, the unit staying active with the old file already read. The value
    # must change to cause the restart: increment the date.
    mautrix-meta-instagram.restartTriggers = ["meta-config-2026-11-13-verification3"];
    mautrix-meta-messenger.restartTriggers = ["meta-config-2026-11-13-verification3"];

    # nixpkgs BUG (verified 25/09/2026, still present on master): the registration
    # unit chgrp's the meta-registration.yaml to the group
    # mautrix-meta-registration (of which matrix-synapse is a MEMBER), but the module
    # never adds this group to synapse's SupplementaryGroups. The process
    # therefore does not have it and cannot read the files (0640): synapse refuses
    # to start (the whole homeserver falls). We add it here, as the
    # mautrix-discord module does for its own group.
    matrix-synapse.serviceConfig.SupplementaryGroups = [
      "mautrix-meta-registration"
    ];

    # Synapse reads the *-registration.yaml only at startup: a rewritten
    # as_token (repair, rotation) takes effect only after a restart of the
    # homeserver.
    matrix-synapse.restartTriggers = ["meta-registration-tokens-2026-11-24"];
  };

  # After deployment, login (to be done by marc), once per network:
  #   1. DM the bot (@instagrambot or @messengerbot)
  #   2. send: login
  #   3. the bridge asks for cookies: log in normally in a
  #      private window on instagram.com or messenger.com, devtools + network
  #      tab + graphql XHR filter, right-click on a request, "Copy as cURL
  #      (POSIX)", and paste it all into the DM.
  #   Otherwise, useful cookies: Instagram sessionid, csrftoken, mid, ig_did,
  #   ds_user_id; Facebook/Messenger datr, c_user, sb, xs.
  # Meta can block an account judged suspicious (captcha / phone): enable
  # two-factor authentication to limit the risk.
}
