# services/app-publish-mcp/default.nix
# Mobile publishing MCP server for hermes: App Store Connect (Apple) and
# Google Play Console (mikusnuz/app-publish-mcp). stdio transport: hermes
# spawns the subprocess (mcpServers), so no dedicated systemd unit.
#
# Surface verified by stdio probe on 25/10/2026: 188 tools (135 apple_*,
# 53 google_*) -- the README advertises "91 tools", which is wrong (real count measured,
# not the doc). The server starts WITHOUT credentials ("Apple: N/A, Google: N/A")
# and serves the whole list.
#
# What it does NOT do (important for winnie): it does not create the listings
# (first publish is manual in Play Console / App Store Connect) and
# signs nothing -- hand it the signed AAB (tauri android build --aab) or the IPA.
# Personal Play account created after 13/11/2023: closed test 12 testers
# opt-in 14 consecutive days before being able to request production access.
# Paid Apple account required for TestFlight/App Store (see skill wingy-nix).
#
# Auth (two independent channels, one can live without the other):
#  - Google: service account JSON (Play Android Developer API enabled +
#    service account invited in Play Console > Users and permissions,
#    "Releases" rights).
#  - Apple: .p8 key role App Manager + Key ID + Issuer ID (reports/finance:
#    "Sales and Reports" Admin key in addition, via APPLE_REPORTS_* / APPLE_ADMIN_*,
#    not wired here).
#
# Secrets: secrets/app-publish.yml (sops, keys apple_key_id, apple_issuer_id,
# apple_p8, google_service_account_json). PLACEHOLDERS today: the file
# exists so the wiring is verified end to end, but the values are
# fake. Recipe when marc has the real accounts:
#   1. replace the content by recreating the file (hermes's age key cannot
#      edit an existing sops file):
#      nix run nixpkgs#sops -- -e --filename-override secrets/app-publish.yml \
#        --output secrets/app-publish.yml <plain-file.yml>
#   2. nixos-rebuild switch (or let the next switch pick it up),
#   3. probe the server (stdio probe): the tools must return an error
#      from the provider (401/invalid_grant) and no longer "placeholder".
# As long as the placeholders are in place, the tools exist but every
# call fails on the provider side: do not promise a possible publication.
{ pkgs, config, ... }:
let
  app-publish = pkgs.callPackage ./package.nix { };

  appleKeyIdFile = config.sops.secrets."app-publish/apple_key_id".path;
  appleIssuerFile = config.sops.secrets."app-publish/apple_issuer_id".path;
  appleP8File = config.sops.secrets."app-publish/apple_p8".path;
  googleSaFile =
    config.sops.secrets."app-publish/google_service_account_json".path;

  # Wrapper: the server expects VALUES in the env (Key ID, Issuer ID) which
  # have no business in the nix store (world-readable); the wrapper reads them
  # from the sops files at each launch. The .p8 and the Google JSON are
  # passed by PATH, the server re-reads them itself.
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

  # On the PATH to probe the server by hand (stdio).
  environment.systemPackages = [ app-publish ];

  services.hermes-agent.mcpServers.app-publish = {
    command = "${wrapper}";
    # Uploads (AAB/IPA) and Apple reports can take minutes.
    timeout = 600;
  };
}
