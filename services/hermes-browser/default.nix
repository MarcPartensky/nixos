# services/hermes-browser: everything Hermes needs to drive a
# browser in place of marc, grouped in the same place.
#
# - firefox-mac.nix: "firefox-mac" MCP, attached in --connectExisting to the
#   Mac's DAILY Firefox (launched by launchd with Marionette/BiDi on
#   loopback, on the Mac side: modules/home-mac/firefox-hermes).
# - bitwarden.nix: hermes user's `bw` CLI, "bitwarden" backend of the
#   Hermes browser vault (browser_vault), pointed at tower's
#   Vaultwarden (vault.marcpartensky.com).
#
# Outside this folder, as they are tied to other stacks: services/firefox-mcp
# (tower's headless LibreWolf) and modules/nixos/kasmvnc-chrome-cdp.nix (the
# Kasm desktop Chromium, the only browser where browser_vault knows how to fill a
# form, it goes through CDP which Firefox no longer has).
{...}: {
  imports = [
    ./firefox-mac.nix
    ./bitwarden.nix
  ];
}
