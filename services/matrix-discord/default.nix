# services/matrix-discord/default.nix
# Pont Matrix <-> Discord (mautrix-discord), serveur : ../matrix
{
  ...
}: let
  dataDir = "/var/lib/mautrix-discord";
in {
  services.mautrix-discord = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:8008";
        domain = "matrix.marcpartensky.com";
      };

      # ATTENTION : le module déclare homeserver/appservice/bridge en
      # `types.attrs` SANS fusion (contrairement à mautrix-signal et
      # mautrix-whatsapp qui font un recursiveUpdate) : dès qu'on écrit dans
      # une de ces clés, TOUT le défaut de la clé est remplacé. On recopie donc
      # ici le défaut du module nixpkgs 26.05 en ne changeant que ce qu'on veut
      # (hostname 0.0.0.0 -> 127.0.0.1).
      appservice = {
        address = "http://127.0.0.1:29334";
        hostname = "127.0.0.1";
        port = 29334;
        database = {
          type = "sqlite3";
          uri = "file:${dataDir}/mautrix-discord.db?_txlock=immediate";
          max_open_conns = 20;
          max_idle_conns = 2;
          max_conn_idle_time = null;
          max_conn_lifetime = null;
        };
        id = "discord";
        bot = {
          username = "discordbot";
          displayname = "Discord bridge bot";
          avatar = "mxc://maunium.net/nIdEykemnwdisvHbpxflpDlC";
        };
        ephemeral_events = true;
        async_transactions = false;
        as_token = "This value is generated when generating the registration";
        hs_token = "This value is generated when generating the registration";
      };

      # idem : le défaut du module met permissions."*" = "relay" (toute
      # l'instance peut relayer) ; on restreint au domaine de marc + admin.
      bridge = {
        command_prefix = "!discord";
        permissions = {
          "matrix.marcpartensky.com" = "user";
          "@marc:matrix.marcpartensky.com" = "admin";
        };
        # défaut du bridge : pas de chiffrement (Discord sert surtout pour des
        # salons de serveurs). Passer allow/default/require à true pour des
        # portails chiffrés.
        encryption = {
          allow = false;
          default = false;
          require = false;
        };
      };
    };
  };

  # Pas d'inversion de dépendance ici : le module crée
  # mautrix-discord-registration.service et fait démarrer matrix-synapse après
  # lui (contrairement à whatsapp/signal qui génèrent la registration dans le
  # preStart du service lui-même).
  #
  # Après déploiement, connexion Discord (à faire par marc), dans le DM de
  # @discordbot:matrix.marcpartensky.com :
  #   login-qr                   scan avec l'app Discord mobile (CAPTCHA non géré)
  #   login-token user <token>   self-bot : header Authorization depuis F12,
  #                              contraire aux CGU Discord
  #   login-token bot <token>    app + bot dédiés sur discord.com/developers,
  #                              intents Server Members + Message Content, puis
  #                              ajouter le bot aux serveurs (pas de MP perso)
}
