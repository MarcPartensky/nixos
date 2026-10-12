# services/zitadel-mcp/default.nix
#
# Upstream: https://github.com/takleb3rry/zitadel-mcp  (MIT, npm: zitadel-mcp-server)
# 34 tools live by default (verified with a real tools/list handshake): users,
# projects, applications (create_oidc_app / update_app / list_apps / get_app),
# roles, org managers, service accounts, login policy, login texts, plus
# idempotent provisioning and offboarding. The README advertises 37: the three
# extra ones are gated, zitadel_set_self_registration behind
# ZITADEL_ENABLE_LOGIN_POLICY_WRITE and the two portal_* tools behind
# PORTAL_DATABASE_URL, neither of which is set here.
#
# This replaces a hand-written Python server that lived here before. That one
# exposed 15 tools with no application management at all, and its PAT was a
# never-filled placeholder, so every call answered HTTP 401.
#
# Auth is a service-account JSON key (signed JWT), not a PAT. Create it in the
# console: Users -> Service Users -> New with Access Token Type "Bearer", then
# on the service user Keys -> New -> JSON, then Organization -> Authorizations
# to grant the account ORG_OWNER. Give it ORG_OWNER rather than
# ORG_USER_MANAGER: ORG_USER_MANAGER is enough to create users and assign
# existing project roles, but creating project roles and managing applications
# needs ORG_OWNER.
#
# The four values plus the issuer live in ONE sops secret holding a dotenv
# file, referenced through DOTENV_CONFIG_PATH, so nothing provider-specific
# stays in this module.
#
# Debug by hand, as hermes:
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | DOTENV_CONFIG_PATH=... /nix/store/.../bin/zitadel-mcp
# (keep stdin open: an EOF kills the request in flight)
{pkgs, config, ...}: let
  # The published npm tarball already ships the compiled build/, so this
  # derivation only installs the runtime dependencies: there is nothing to
  # compile, hence dontNpmBuild.
  #
  # Upstream ships no package-lock.json (the repository has none). The one
  # committed next to this file was generated with
  # `npm install --package-lock-only` from the published package.json,
  # dependencies only, so the dependency set is pinned without dragging in the
  # devDependencies (tsc, vitest, tsx) that are useless here. Regenerate it when
  # bumping the version.
  zitadel-mcp = pkgs.buildNpmPackage {
    pname = "zitadel-mcp-server";
    version = "2.0.0";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/zitadel-mcp-server/-/zitadel-mcp-server-2.0.0.tgz";
      hash = "sha256-+PvZY0GYPxis8VxOR0ejSh+gqn4uKqH9ANFGrqaT5gk=";
    };
    npmDepsHash = "sha256-i6lYVprSJUkGmZupmbuSykK29wBTOsJOk0NVgj3V3dc=";
    dontNpmBuild = true;
    postPatch = ''
      cp ${./package-lock.json} package-lock.json
      # The committed lock covers the runtime dependencies only (npm refuses to
      # compose a lock for this manifest once devDependencies are present), and
      # npm ci refuses a manifest that disagrees with its lock. Drop them from
      # the manifest: nothing is compiled here, so they were dead weight.
      ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';
  };
in {
  # Content of this secret (a dotenv file):
  #   ZITADEL_ISSUER=https://<ton instance>
  #   ZITADEL_SERVICE_ACCOUNT_USER_ID=...
  #   ZITADEL_SERVICE_ACCOUNT_KEY_ID=...
  #   ZITADEL_SERVICE_ACCOUNT_PRIVATE_KEY=<RSA en base64, le champ "key" du JSON>
  #   ZITADEL_ORG_ID=...
  # secrets/zitadel.yml rather than tower.yml: hermes can write this one.
  sops.secrets."zitadel_mcp_env" = {
    sopsFile = ../../secrets/zitadel.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
    restartUnits = ["hermes-agent.service"];
  };

  services.hermes-agent.mcpServers.zitadel = {
    command = "${zitadel-mcp}/bin/zitadel-mcp";
    env = {
      DOTENV_CONFIG_PATH = config.sops.secrets."zitadel_mcp_env".path;
      LOG_LEVEL = "WARN";
      # Read-only first: the write tools stay visible but refuse to mutate, so
      # the tool list and the permissions can be checked before granting
      # anything. Drop the line (or set "false") once that is done.
      ZITADEL_READ_ONLY = "true";
    };
  };
}