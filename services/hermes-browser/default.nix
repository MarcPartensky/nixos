# services/hermes-browser : tout ce qui sert à Hermes pour piloter un
# navigateur à la place de marc, regroupé au même endroit.
#
# - firefox-mac.nix : MCP « firefox-mac », attaché en --connectExisting au
#   Firefox QUOTIDIEN du Mac (lancé par launchd avec Marionette/BiDi en
#   loopback, côté Mac : modules/home-mac/firefox-hermes).
# - bitwarden.nix : CLI `bw` de l'utilisateur hermes, backend « bitwarden » du
#   coffre navigateur Hermes (browser_vault), pointé sur le Vaultwarden de
#   tower (vault.marcpartensky.com).
#
# Hors de ce dossier, car liés à d'autres piles : services/firefox-mcp
# (LibreWolf headless de tower) et modules/nixos/kasmvnc-chrome-cdp.nix (le
# Chromium du bureau Kasm, seul navigateur où browser_vault sait remplir un
# formulaire, il passe par CDP que Firefox n'a plus).
{...}: {
  imports = [
    ./firefox-mac.nix
    ./bitwarden.nix
  ];
}
