# services/anki-mcp/default.nix
# Headless Anki MCP server: Anki (no desktop, under Xvfb) + AnkiMCP addon
# (ankimcp.ai), which exposes the collection over MCP HTTP on loopback.
#
# Architecture choice: the AnkiMCP addon runs INSIDE Anki (no separate
# process, no AnkiConnect to install), so the only way to make it a
# service is to run Anki without a screen. This service's collection
# and your desktop Anki's (Mac, phone) reconcile through the
# self-hosted sync server (services/anki-sync-server), whose secret this module
# borrows: a single account, a single collection, several clients.
#
# Details that cost time if ignored:
#  - Anki reads its addon list from $ANKI_ADDONS when this variable is
#    set (nixpkgs patch), otherwise from <base>/addons21. We therefore build a
#    dedicated addon folder: the AnkiMCP addon plus a small bootstrap addon,
#    because Anki offers NO non-interactive path to enter the sync server
#    and account (entry goes through the preferences
#    dialog). The bootstrap addon logs in on profile load and
#    persists the key, which mw.pm.sync_auth() then reads, hence the `sync` tool.
#  - The "nixos" addon shipped by pkgs.anki.withAddons is NOT used here: it
#    replaces addonManager.writeConfig with a modal dialog,
#    unworkable without a screen.
#  - Anki comes from the nixpkgs of the anki-mcp input, the one that built the addon:
#    the addon there is linked against its python interpreter (3.14) via vendor/shared,
#    another nixpkgs breaks the ABI of the compiled modules (pydantic_core).
#  - No -p <profile> on first startup: the profile does not exist yet and
#    Anki would then show the profile selector (modal). Without -p, Anki creates
#    the single profile on its own then loads it silently.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.anki-mcp;

  system = pkgs.stdenv.hostPlatform.system;

  # nixpkgs that built the addon AND the Anki package (cf header).
  ankiPkgs = inputs.anki-mcp.inputs.nixpkgs.legacyPackages.${system};
  mcpAddon = inputs.anki-mcp.packages.${system}.addon;

  # Bootstrap addon: attaches the profile to the sync server (login once).
  bootstrapAddon = pkgs.runCommand "anki-addon-ankimcp-sync-bootstrap" { } ''
    mkdir -p $out/share/anki/addons/ankimcp_sync_bootstrap
    cp ${./bootstrap/__init__.py} $out/share/anki/addons/ankimcp_sync_bootstrap/__init__.py
    cp ${./bootstrap/manifest.json} $out/share/anki/addons/ankimcp_sync_bootstrap/manifest.json
  '';

  # The addon folder of the input is read-only (store), so we always build a
  # writable copy. It carries two changes:
  #  - extra_tools/delete_deck_tool.py: a `delete_deck` tool the upstream addon
  #    lacks. Deck restructurings leave empty shells that cannot be deleted
  #    through the API. Tools are auto-discovered by pkgutil in
  #    primitives/essential/tools/, a plain cp is enough. Drop the injection if
  #    upstream ever ships delete_deck.
  #  - AnkiMCP protects its HTTP transport against DNS-rebinding: the Host of the
  #    LAN URL (192.168.1.44:3141) is accepted only if it appears in
  #    http_allowed_hosts, otherwise the server answers 421 Misdirected Request.
  #    Patched only when LAN access is enabled.
  mcpAddonPatched = pkgs.runCommand "anki-addon-anki-mcp-server-patched" { } (''
    mkdir -p $out
    cp -r ${mcpAddon}/share/anki/addons/anki-mcp-server/. $out/
    chmod -R u+w $out
    cp ${./extra_tools/delete_deck_tool.py} \
      $out/primitives/essential/tools/delete_deck_tool.py
  '' + lib.optionalString config.services.mcp-lan-access.enable ''
    ${pkgs.jq}/bin/jq --arg host "${config.services.mcp-lan-access.host}:${toString port}" \
      '.http_allowed_hosts = [$host]' $out/config.json > $out/config.json.new
    mv $out/config.json.new $out/config.json
  '');

  # Anki's addon folder ($ANKI_ADDONS): a simple directory of links.
  addonsDir = pkgs.runCommand "ankimcp-addons" { } ''
    mkdir -p $out
    ln -s ${mcpAddonPatched} $out/anki-mcp-server
    ln -s ${bootstrapAddon}/share/anki/addons/ankimcp_sync_bootstrap $out/ankimcp_sync_bootstrap
  '';

  stateDir = "/var/lib/anki-mcp";
  port = 3141;

  # As long as prefs21.db does not exist, Anki thinks it is the first launch and
  # opens a modal language selector that blocks opening the profile: we
  # seed the file once (cf the header of seed-prefs.py).
  seedPrefs = pkgs.writeShellScript "anki-mcp-seed-prefs" ''
    exec ${pkgs.python3}/bin/python3 ${./seed-prefs.py} ${stateDir}/anki/prefs21.db
  '';

  start = pkgs.writeShellScript "anki-mcp-start" ''
    set -eu
    # All of Anki's state lives under $HOME (profile, collection, media, logs).
    export HOME=${stateDir}
    export ANKI_SYNC_USER=${cfg.syncUser}
    export ANKI_SYNC_ENDPOINT=${cfg.syncEndpoint}
    export ANKI_SYNC_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/anki-sync-password"

    # Anki writes into its profile: the -b path stays under $HOME so that
    # DynamicUser and StateDirectory are enough (no /home/user involved).
    exec ${pkgs.xvfb-run}/bin/xvfb-run -a -s "-screen 0 1280x1024x24" \
      ${ankiPkgs.anki}/bin/anki -b ${stateDir}/anki
  '';
in {
  options.services.anki-mcp = {
    enable = lib.mkEnableOption "headless Anki MCP server (Anki + AnkiMCP addon)";

    syncUser = lib.mkOption {
      type = lib.types.str;
      default = "marc";
      description = "Anki sync server account used by the headless instance.";
    };

    syncEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://anki.marcpartensky.com";
      description = ''
        Sync server URL (services/anki-sync-server). The password
        comes from the anki-sync-server/password secret, read by LoadCredential.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.anki-mcp = {
      description = "Anki + AnkiMCP headless (Anki MCP server for the agent)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Sync is driven by the MCP's `sync` tool, not at startup:
      # cf the bootstrap addon (autoSync disabled).
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "anki-mcp";
        RuntimeDirectory = "anki-mcp";
        WorkingDirectory = stateDir;
        # Same account as the sync server: the secret is already there.
        LoadCredential = "anki-sync-password:${config.sops.secrets."anki-sync-server/password".path}";
        ExecStartPre = seedPrefs;
        ExecStart = start;
        Restart = "always";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
      };
      environment = {
        ANKI_ADDONS = "${addonsDir}";
        # Qt/WebEngine without a screen: software rendering, no sandbox.
        # DISPLAY is set by xvfb-run (free display chosen at runtime).
        QTWEBENGINE_DISABLE_SANDBOX = "1";
        QTWEBENGINE_CHROMIUM_FLAGS = "--disable-gpu";
        LIBGL_ALWAYS_SOFTWARE = "1";
        QT_QPA_PLATFORM = "xcb";
        QT_XKB_CONFIG_ROOT = "${pkgs.xkeyboard_config}/share/X11/xkb";
        LANG = "C.UTF-8";
      };
    };

    # Hermes wiring: the MCP is consumed by URL (HTTP transport), like
    # nextcloud or arrmcp. The port stays on loopback and nothing is opened on the
    # firewall. The LAN URL of the services/mcp-lan-access module only makes
    # the link clickable from Hermes Desktop on the Mac; the firewall
    # restricts it to the Mac and tower reaches it via lo.
    # Possible public exposure: go through a dedicated Pangolin/newt
    # resource (services/newt) with http_api_key + http_allowed_hosts set in
    # the addon config, never without a key.
    services.hermes-agent.mcpServers.anki = {
      url =
        if config.services.mcp-lan-access.enable
        then "http://${config.services.mcp-lan-access.host}:${toString port}/"
        else "http://127.0.0.1:${toString port}/";
      timeout = 120;
    };
  };
}
