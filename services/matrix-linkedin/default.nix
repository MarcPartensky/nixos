# services/matrix-linkedin/default.nix
# Pont Matrix <-> LinkedIn (mautrix-linkedin).
# Contrairement aux autres bridges, il n'existe PAS de module nixpkgs pour
# mautrix-linkedin : paquet, unité systemd et registration sont donc câblés ici.
# Le binaire amont est un binaire statique publié dans les releases GitHub
# (les bridges Go de mautrix n'ont pas de build nixpkgs pour LinkedIn).
{
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/mautrix-linkedin";
  appservicePort = 29329;

  mautrix-linkedin = pkgs.stdenvNoCC.mkDerivation {
    pname = "mautrix-linkedin";
    version = "0.2609.0";

    src = pkgs.fetchurl {
      url = "https://github.com/mautrix/linkedin/releases/download/v0.2609.0/mautrix-linkedin-amd64";
      hash = "sha256-6FrEDJRQWJm4Ib/WJtpmRPJVp9RYsxQ1X0YtaePQ1k0=";
    };

    dontUnpack = true;
    installPhase = ''
      install -Dm755 $src $out/bin/mautrix-linkedin
    '';

    meta = {
      description = "A Matrix-LinkedIn puppeting bridge";
      homepage = "https://github.com/mautrix/linkedin";
      license = lib.licenses.agpl3Only;
      platforms = ["x86_64-linux"];
      mainProgram = "mautrix-linkedin";
    };
  };

  settingsFormat = pkgs.formats.yaml {};

  settings = {
    homeserver = {
      address = "http://127.0.0.1:8008";
      domain = "matrix.marcpartensky.com";
      software = "standard";
    };
    appservice = {
      id = "linkedin";
      # address = ce que synapse utilisera pour joindre l'appservice (et ce qui
      # finit dans le champ url de la registration) : il DOIT correspondre au
      # port écouté, sinon la registration annonce le défaut 29341.
      address = "http://127.0.0.1:${toString appservicePort}";
      hostname = "127.0.0.1";
      port = appservicePort;
      bot = {
        username = "linkedinbot";
        displayname = "LinkedIn bridge bot";
        avatar = "mxc://maunium.net/CqzBEHjrLsfdqixWZgNHMlRT";
      };
      ephemeral_events = true;
      username_template = "linkedin_{{.}}";
    };
    # ATTENTION (vérifié à la main) : en config "nouvelle génération", database
    # et encryption sont au niveau RACINE, pas sous appservice/bridge. Les y
    # mettre déclenche "Legacy bridge config detected" au démarrage.
    database = {
      type = "sqlite3-fk-wal";
      uri = "file:${dataDir}/mautrix-linkedin.db?_txlock=immediate";
    };
    encryption = {
      allow = true;
      default = true;
      require = false;
      # le défaut du bridge est "generate" (clé différente à chaque démarrage,
      # donc DB crypto illisible après restart) : valeur stable hors du store.
      pickle_key = "$ENCRYPTION_PICKLE_KEY";
    };
    bridge = {
      command_prefix = "!linkedin";
      permissions = {
        "matrix.marcpartensky.com" = "user";
        "@marc:matrix.marcpartensky.com" = "admin";
      };
    };
  };

  settingsFileUnsubstituted = settingsFormat.generate "mautrix-linkedin-config.yaml" settings;
  settingsFile = "${dataDir}/config.yaml";
  registrationFile = "${dataDir}/linkedin-registration.yaml";
in {
  users.users.mautrix-linkedin = {
    isSystemUser = true;
    group = "mautrix-linkedin";
    home = dataDir;
    description = "Mautrix-LinkedIn bridge user";
  };
  users.groups.mautrix-linkedin = {};

  systemd.services.mautrix-linkedin = {
    description = "Mautrix-LinkedIn, a Matrix-LinkedIn puppeting bridge";
    wantedBy = ["multi-user.target"];
    # pas de dépendance à synapse : c'est synapse qui nous attend, parce que la
    # registration est générée dans notre preStart (cf. services/matrix).
    wants = ["network-online.target"];
    after = ["network-online.target"];
    path = [
      pkgs.envsubst
      pkgs.yq
      pkgs.openssl
      pkgs.ffmpeg-headless
    ];

    preStart = ''
      if [ ! -f ${dataDir}/pickle_key.txt ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${dataDir}/pickle_key.txt
        chmod 600 ${dataDir}/pickle_key.txt
      fi
      export ENCRYPTION_PICKLE_KEY=$(cat ${dataDir}/pickle_key.txt)

      # substitution des $VAR du store dans le vrai config.yaml (umask 0177 :
      # il contient les tokens appservice)
      rm -f '${settingsFile}'
      old_umask=$(umask)
      umask 0177
      ${pkgs.envsubst}/bin/envsubst -o '${settingsFile}' -i '${settingsFileUnsubstituted}'

      if [ ! -f '${registrationFile}' ]; then
        ${lib.getExe mautrix-linkedin} \
          --config='${settingsFile}' \
          --generate-registration \
          --registration='${registrationFile}'
      fi
      chmod 640 '${registrationFile}'

      # remet les tokens de la registration dans le config : sans ça, un restart
      # repartirait sur le placeholder du store et casserait le sync.
      ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
        | .[0].appservice.hs_token = .[1].hs_token
        | .[0]' \
        '${settingsFile}' '${registrationFile}' > '${settingsFile}.tmp'
      mv '${settingsFile}.tmp' '${settingsFile}'
      umask $old_umask
    '';

    serviceConfig = {
      Type = "simple";
      User = "mautrix-linkedin";
      Group = "mautrix-linkedin";
      WorkingDirectory = dataDir;
      StateDirectory = "mautrix-linkedin";
      Environment = ["HOME=${dataDir}"];
      ExecStart = "${lib.getExe mautrix-linkedin} --config='${settingsFile}'";
      Restart = "on-failure";
      RestartSec = 30;

      # même durcissement que les modules nixpkgs
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };

    restartTriggers = [settingsFileUnsubstituted];
  };

  # Lecture de la registration par synapse (fichier 0640, groupe du bridge).
  services.matrix-synapse = {
    settings.app_service_config_files = [registrationFile];
  };
  systemd.services.matrix-synapse.serviceConfig.SupplementaryGroups = ["mautrix-linkedin"];

  # Après déploiement, connexion (à faire par marc) : DM à
  # @linkedinbot:matrix.marcpartensky.com, `login`, puis identifiants LinkedIn.
}
