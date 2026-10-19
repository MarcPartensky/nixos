# services/anki-mcp/default.nix
# Serveur MCP Anki headless : Anki (sans bureau, sous Xvfb) + addon AnkiMCP
# (ankimcp.ai), qui expose la collection en HTTP MCP sur la loopback.
#
# Choix d'architecture : l'addon AnkiMCP tourne DANS Anki (aucun processus
# séparé, aucun AnkiConnect à installer), donc la seule façon d'en faire un
# service est de faire tourner un Anki sans écran. La collection de ce service
# et celle de ton Anki de bureau (Mac, téléphone) se réconcilient par le
# serveur de sync auto-hébergé (services/anki-sync-server), dont ce module
# emprunte le secret : un seul compte, une seule collection, plusieurs clients.
#
# Détails qui coûtent du temps si on les ignore :
#  - Anki lit sa liste d'addons dans $ANKI_ADDONS quand cette variable est
#    posée (patch nixpkgs), sinon dans <base>/addons21. On construit donc un
#    dossier d'addons dédié : l'addon AnkiMCP plus un petit addon d'amorçage,
#    car Anki n'offre AUCUN chemin non interactif pour renseigner le serveur de
#    sync et le compte (la saisie passe par la boîte de dialogue des
#    préférences). L'addon d'amorçage fait le login au chargement du profil et
#    persiste la clé, ce que lit ensuite mw.pm.sync_auth() donc l'outil `sync`.
#  - L'addon "nixos" livré par pkgs.anki.withAddons n'est PAS repris ici : il
#    remplace addonManager.writeConfig par une boîte de dialogue modale,
#    intenable sans écran.
#  - Anki vient du nixpkgs de l'input anki-mcp, celui qui a construit l'addon :
#    l'addon y est lié contre son interpréteur python (3.14) via vendor/shared,
#    un autre nixpkgs casse l'ABI des modules compilés (pydantic_core).
#  - Pas de -p <profil> au premier démarrage : le profil n'existe pas encore et
#    Anki afficherait alors le sélecteur de profils (modal). Sans -p, Anki crée
#    le profil unique tout seul puis le charge silencieusement.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.anki-mcp;

  system = pkgs.stdenv.hostPlatform.system;

  # nixpkgs qui a construit l'addon ET le paquet Anki (cf en-tête).
  ankiPkgs = inputs.anki-mcp.inputs.nixpkgs.legacyPackages.${system};
  mcpAddon = inputs.anki-mcp.packages.${system}.addon;

  # Addon d'amorçage : rattache le profil au serveur de sync (login une fois).
  bootstrapAddon = pkgs.runCommand "anki-addon-ankimcp-sync-bootstrap" { } ''
    mkdir -p $out/share/anki/addons/ankimcp_sync_bootstrap
    cp ${./bootstrap/__init__.py} $out/share/anki/addons/ankimcp_sync_bootstrap/__init__.py
    cp ${./bootstrap/manifest.json} $out/share/anki/addons/ankimcp_sync_bootstrap/manifest.json
  '';

  # AnkiMCP protège son transport HTTP contre le DNS-rebinding : le Host de
  # l'URL LAN (192.168.1.44:3141) n'est accepté que s'il figure dans
  # http_allowed_hosts, sinon le serveur répond 421 Misdirected Request. Le
  # dossier d'addon de l'input est en lecture seule (store), on en fait donc
  # une copie dont seul config.json change. La copie n'est utilisée que quand
  # l'accès LAN est activé.
  mcpAddonForLan = pkgs.runCommand "anki-addon-anki-mcp-server-lan" { } ''
    mkdir -p $out
    cp -r ${mcpAddon}/share/anki/addons/anki-mcp-server/. $out/
    chmod -R u+w $out
    ${pkgs.jq}/bin/jq --arg host "${config.services.mcp-lan-access.host}:${toString port}" \
      '.http_allowed_hosts = [$host]' $out/config.json > $out/config.json.new
    mv $out/config.json.new $out/config.json
  '';

  # Dossier d'addons d'Anki ($ANKI_ADDONS) : un simple répertoire de liens.
  addonsDir = pkgs.runCommand "ankimcp-addons" { } ''
    mkdir -p $out
    ln -s ${
      if config.services.mcp-lan-access.enable
      then mcpAddonForLan
      else "${mcpAddon}/share/anki/addons/anki-mcp-server"
    } $out/anki-mcp-server
    ln -s ${bootstrapAddon}/share/anki/addons/ankimcp_sync_bootstrap $out/ankimcp_sync_bootstrap
  '';

  stateDir = "/var/lib/anki-mcp";
  port = 3141;

  # Tant que prefs21.db n'existe pas, Anki se croit au premier lancement et
  # ouvre un sélecteur de langue modal qui bloque l'ouverture du profil : on
  # amorce le fichier une fois (cf l'en-tête de seed-prefs.py).
  seedPrefs = pkgs.writeShellScript "anki-mcp-seed-prefs" ''
    exec ${pkgs.python3}/bin/python3 ${./seed-prefs.py} ${stateDir}/anki/prefs21.db
  '';

  start = pkgs.writeShellScript "anki-mcp-start" ''
    set -eu
    # Tout l'état d'Anki vit sous $HOME (profil, collection, medias, logs).
    export HOME=${stateDir}
    export ANKI_SYNC_USER=${cfg.syncUser}
    export ANKI_SYNC_ENDPOINT=${cfg.syncEndpoint}
    export ANKI_SYNC_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/anki-sync-password"

    # Anki écrit dans son profil : le chemin -b reste sous $HOME pour que
    # DynamicUser et StateDirectory suffisent (aucun /home/user en jeu).
    exec ${pkgs.xvfb-run}/bin/xvfb-run -a -s "-screen 0 1280x1024x24" \
      ${ankiPkgs.anki}/bin/anki -b ${stateDir}/anki
  '';
in {
  options.services.anki-mcp = {
    enable = lib.mkEnableOption "serveur MCP Anki headless (Anki + addon AnkiMCP)";

    syncUser = lib.mkOption {
      type = lib.types.str;
      default = "marc";
      description = "Compte du serveur de sync Anki utilisé par l'instance headless.";
    };

    syncEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://anki.marcpartensky.com";
      description = ''
        URL du serveur de sync (services/anki-sync-server). Le mot de passe
        vient du secret anki-sync-server/password, lu par LoadCredential.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.anki-mcp = {
      description = "Anki + AnkiMCP headless (serveur MCP Anki pour l'agent)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # La sync est pilotée par l'outil `sync` du MCP, pas au démarrage :
      # cf l'addon d'amorçage (autoSync désactivé).
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "anki-mcp";
        RuntimeDirectory = "anki-mcp";
        WorkingDirectory = stateDir;
        # Même compte que le serveur de sync : le secret est déjà là.
        LoadCredential = "anki-sync-password:${config.sops.secrets."anki-sync-server/password".path}";
        ExecStartPre = seedPrefs;
        ExecStart = start;
        Restart = "always";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
      };
      environment = {
        ANKI_ADDONS = "${addonsDir}";
        # Qt/WebEngine sans écran : rendu logiciel, pas de bac à sable.
        # DISPLAY est posé par xvfb-run (display libre choisi à l'exécution).
        QTWEBENGINE_DISABLE_SANDBOX = "1";
        QTWEBENGINE_CHROMIUM_FLAGS = "--disable-gpu";
        LIBGL_ALWAYS_SOFTWARE = "1";
        QT_QPA_PLATFORM = "xcb";
        QT_XKB_CONFIG_ROOT = "${pkgs.xkeyboard_config}/share/X11/xkb";
        LANG = "C.UTF-8";
      };
    };

    # Câblage Hermes : le MCP est consommé par URL (transport HTTP), comme
    # nextcloud ou arrmcp. Le port reste sur la loopback et rien n'est ouvert au
    # firewall. L'URL LAN du module services/mcp-lan-access ne fait que rendre
    # le lien cliquable depuis Hermes Desktop sur le Mac ; le firewall la
    # restreint au Mac et tower la joint par lo.
    # Exposition publique éventuelle : passer par une ressource Pangolin/newt
    # dédiée (services/newt) avec http_api_key + http_allowed_hosts posés dans
    # la config de l'addon, jamais sans clé.
    services.hermes-agent.mcpServers.anki = {
      url =
        if config.services.mcp-lan-access.enable
        then "http://${config.services.mcp-lan-access.host}:${toString port}/"
        else "http://127.0.0.1:${toString port}/";
      timeout = 120;
    };
  };
}
