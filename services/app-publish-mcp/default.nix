# services/app-publish-mcp/default.nix
# Serveur MCP de publication mobile pour hermes : App Store Connect (Apple) et
# Google Play Console (mikusnuz/app-publish-mcp). Transport stdio : hermes
# spawn le subprocess (mcpServers), donc pas d'unite systemd dediee.
#
# Surface verifiee par sonde stdio le 25/10/2026 : 188 tools (135 apple_*,
# 53 google_*) — le README annonce "91 tools", c'est faux (compte reel mesure,
# pas la doc). Le serveur demarre SANS credentials ("Apple: N/A, Google: N/A")
# et sert toute la liste.
#
# Ce qu'il ne fait PAS (important pour winnie) : il ne cree pas les fiches
# (premiere mise en ligne manuelle dans Play Console / App Store Connect) et
# ne signe rien — lui livrer l'AAB signe (tauri android build --aab) ou l'IPA.
# Compte Play personnel cree apres le 13/11/2023 : closed test 12 testeurs
# opt-in 14 jours consecutifs avant de pouvoir demander l'acces production.
# Compte Apple payant requis pour TestFlight/App Store (voir skill wingy-nix).
#
# Auth (deux canaux independants, l'un peut vivre sans l'autre) :
#  - Google : service account JSON (API Play Android Developer activee +
#    compte de service invite dans Play Console > Utilisateurs et permissions,
#    droits "Versions").
#  - Apple : cle .p8 role App Manager + Key ID + Issuer ID (reports/finance :
#    cle "Sales and Reports" Admin en plus, via APPLE_REPORTS_* / APPLE_ADMIN_*,
#    non cable ici).
#
# Secrets : secrets/app-publish.yml (sops, cles apple_key_id, apple_issuer_id,
# apple_p8, google_service_account_json). PLACEHOLDERS aujourd'hui : le fichier
# existe pour que le wiring soit verifie de bout en bout, mais les valeurs sont
# factices. Recette quand marc a les vrais comptes :
#   1. remplacer le contenu en recreant le fichier (la cle age de hermes ne
#      peut pas editer un sops existant) :
#      nix run nixpkgs#sops -- -e --filename-override secrets/app-publish.yml \
#        --output secrets/app-publish.yml <fichier-plain.yml>
#   2. nixos-rebuild switch (ou laisser le prochain switch le prendre),
#   3. sonder le serveur (sonde stdio) : les tools doivent remonter une erreur
#      du fournisseur (401/invalid_grant) et non plus "placeholder".
# Tant que les placeholders sont en place, les tools existent mais chaque
# appel echoue cote fournisseur : ne pas promettre une publication possible.
{ pkgs, config, ... }:
let
  app-publish = pkgs.callPackage ./package.nix { };

  appleKeyIdFile = config.sops.secrets."app-publish/apple_key_id".path;
  appleIssuerFile = config.sops.secrets."app-publish/apple_issuer_id".path;
  appleP8File = config.sops.secrets."app-publish/apple_p8".path;
  googleSaFile =
    config.sops.secrets."app-publish/google_service_account_json".path;

  # Wrapper : le serveur attend des VALEURS dans l'env (Key ID, Issuer ID) qui
  # n'ont rien a faire dans le nix store (world-readable) ; le wrapper les lit
  # dans les fichiers sops a chaque lancement. Le .p8 et le JSON Google sont
  # passes par CHEMIN, le serveur les relit lui-meme.
  wrapper = pkgs.writeShellScript "app-publish-mcp-hermes" ''
    set -euo pipefail
    export APPLE_KEY_TYPE=TEAM
    export APPLE_KEY_ID="$(cat ${appleKeyIdFile})"
    export APPLE_ISSUER_ID="$(cat ${appleIssuerFile})"
    export APPLE_P8_PATH=${appleP8File}
    export GOOGLE_SERVICE_ACCOUNT_PATH=${googleSaFile}
    exec ${app-publish}/bin/app-publish-mcp
  '';
in {
  sops.secrets."app-publish/apple_key_id" = {
    key = "apple_key_id";
    sopsFile = ../../secrets/app-publish.yml;
    owner = "hermes";
    mode = "0400";
  };
  sops.secrets."app-publish/apple_issuer_id" = {
    key = "apple_issuer_id";
    sopsFile = ../../secrets/app-publish.yml;
    owner = "hermes";
    mode = "0400";
  };
  sops.secrets."app-publish/apple_p8" = {
    key = "apple_p8";
    sopsFile = ../../secrets/app-publish.yml;
    owner = "hermes";
    mode = "0400";
  };
  sops.secrets."app-publish/google_service_account_json" = {
    key = "google_service_account_json";
    sopsFile = ../../secrets/app-publish.yml;
    owner = "hermes";
    mode = "0400";
  };

  # Sur le PATH pour sonder le serveur a la main (stdio).
  environment.systemPackages = [ app-publish ];

  services.hermes-agent.mcpServers.app-publish = {
    command = "${wrapper}";
    # Les uploads (AAB/IPA) et les rapports Apple peuvent prendre des minutes.
    timeout = 600;
  };
}
