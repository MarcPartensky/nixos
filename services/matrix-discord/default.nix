# services/matrix-discord/default.nix
# Pont Matrix <-> Discord (mautrix-discord), serveur : ../matrix
{
  pkgs,
  lib,
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
        # portails chiffrés par défaut (comme whatsapp), require=false pour ne
        # pas casser les salles qui ne peuvent pas être chiffrées (salons de
        # serveurs notamment). pickle_key stable hors du store, cf. l'export
        # ajouté plus bas dans mautrix-discord-registration.
        encryption = {
          allow = true;
          default = true;
          require = false;
          pickle_key = "$ENCRYPTION_PICKLE_KEY";
        };
      };
    };
  };

  # Le module NE génère pas la registration dans le preStart du bridge : c'est
  # mautrix-discord-registration.service qui fait le envsubst du config.yaml puis
  # --generate-registration. L'export de la clé doit donc être DANS ce script
  # (un export dans un ExecStartPre ne survivrait pas au process suivant).
  systemd.services.mautrix-discord-registration.script = lib.mkBefore ''
    if [ ! -f ${dataDir}/pickle_key.txt ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dataDir}/pickle_key.txt
      chmod 600 ${dataDir}/pickle_key.txt
    fi
    export ENCRYPTION_PICKLE_KEY=$(cat ${dataDir}/pickle_key.txt)
  '';

  # Le config.yaml du bridge est régénéré par l'unité de registration, mais le
  # bridge ne le relit pas tout seul : on déclare un trigger de restart pour que
  # le switch redémarre mautrix-discord.service quand ce fichier change.
  systemd.services.mautrix-discord.restartTriggers = [./default.nix];

  # BUG nixpkgs (vérifié 25/09/2026, toujours présent sur master) : le module
  # crée /var/lib/mautrix-discord en 0770 mautrix-discord:mautrix-discord
  # (règle tmpfiles) alors que le fichier de registration est chgrp au groupe
  # mautrix-discord-registration, seul groupe dont synapse est membre. Synapse
  # ne peut donc même pas TRAVERSER le dossier et meurt au démarrage
  # ("PermissionError: /var/lib/mautrix-discord/discord-registration.yaml"),
  # ce qui met tout le homeserver en crash-loop.
  #
  # On remet le dossier dans le groupe de registration, en 0750. ATTENTION au
  # TYPE de la règle : systemd-tmpfiles n'accepte qu'UNE SEULE ligne de type
  # "prise de possession" (d/f/L/c/b/C...) par chemin ; une deuxième ligne `d`
  # est rejetée avec « Duplicate line for path "...", ignoring. » et mkAfter n'y
  # change rien (le premier gagne, donc celui du module). Il faut une ligne `z`
  # (ajustement de mode/propriétaire d'un chemin existant), qui elle cohabite
  # avec le `d` du module. Vérifié en reproduisant les deux cas à la main :
  #   d + d -> "Duplicate line", dossier laissé en 0770 mautrix-discord
  #   d + z -> appliqué, dossier en 0750 ...:mautrix-discord-registration
  systemd.tmpfiles.rules = lib.mkAfter [
    "z ${dataDir} 0750 mautrix-discord mautrix-discord-registration -"
  ];

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
