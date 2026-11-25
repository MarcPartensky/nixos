# services/matrix-linkedin/default.nix
# Matrix <-> LinkedIn bridge (mautrix-linkedin).
# Unlike the other bridges, there is NO nixpkgs module for
# mautrix-linkedin: package, systemd unit and registration are therefore wired here.
# The upstream binary is a static binary published in the GitHub releases
# (mautrix's Go bridges have no nixpkgs build for LinkedIn).
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
      # address = what synapse will use to reach the appservice (and what
      # ends up in the url field of the registration): it MUST match the
      # port listened on, otherwise the registration announces the default 29341.
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
    # WARNING (checked by hand): in "new generation" config, database
    # and encryption are at the ROOT level, not under appservice/bridge. Putting them
    # there triggers "Legacy bridge config detected" on startup.
    database = {
      type = "sqlite3-fk-wal";
      uri = "file:${dataDir}/mautrix-linkedin.db?_txlock=immediate";
    };
    encryption = {
      allow = true;
      default = true;
      require = false;
      # the bridge default is "generate" (different key on each startup,
      # so crypto DB unreadable after restart): stable value outside the store.
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
    # no dependency on synapse: it is synapse that waits for us, because the
    # registration is generated in our preStart (cf. services/matrix).
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

      # substitution of the store's $VAR into the real config.yaml (umask 0177:
      # it contains the appservice tokens)
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

      # puts the registration tokens back into the config: without it, a restart
      # would fall back to the store placeholder and break the sync.
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

      # same hardening as the nixpkgs modules
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

  # Reading of the registration by synapse (file 0640, bridge group).
  services.matrix-synapse = {
    settings.app_service_config_files = [registrationFile];
  };
  systemd.services.matrix-synapse.serviceConfig.SupplementaryGroups = ["mautrix-linkedin"];

  # After deployment, login (to be done by marc): DM to
  # @linkedinbot:matrix.marcpartensky.com, `login`, then LinkedIn credentials.
}
