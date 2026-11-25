# services/stalwart-mcp/default.nix
# MCP server for Stalwart Mail Server (webpatser/stalwart-mcp), in Rust.
# Speaks JMAP to https://mail.vps.marcpartensky.com (Traefik -> 127.0.0.1:8390
# on the VPS): no additional port opening, no mail goes through
# a third party. stdio transport: hermes spawns the binary as a subprocess.
#
# The upstream binary has NO Cargo.lock: the one in the repo was generated
# from the commit pinned in flake.nix (cargo generate-lockfile) and must
# be regenerated on every input bump. Without it, buildRustPackage fails
# (fetch-cargo-vendor requires a lock).
{ pkgs, inputs, config, lib, ... }: let
  stalwart-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "stalwart-mcp";
    version = "0.1.0-unstable-2026-04-14";
    # Upstream has no Cargo.lock: we inject it into the source so that
    # the cargo hook finds it (and to pin the resolved versions).
    src = pkgs.runCommandLocal "stalwart-mcp-source" {} ''
      cp -r ${inputs.stalwart-mcp} $out
      chmod -R u+w $out
      cp ${./Cargo.lock} $out/Cargo.lock
    '';
    cargoHash = "sha256-JVuPj9UTA+77JCeVKRZTBbYOxe8l7KmcyyayfxR0VDc=";
    # Stalwart 0.15 announces its bind address (mx1:8390) in apiUrl when it
    # is behind a reverse proxy; the JMAP client follows this URL and fails.
    # The patch keeps the announced path but reuses the configured origin.
    preBuild = ''
      patch -p1 -d ../$name-vendor/source-registry-0/jmap-client-0.4.3 < ${./jmap-api-url.patch}
      patch -p1 < ${./send-from-identity.patch}
    '';
    meta = {
      description = "Rust MCP server for Stalwart Mail Server - AI mail access via JMAP";
      homepage = "https://github.com/webpatser/stalwart-mcp";
      license = lib.licenses.agpl3Only;
      mainProgram = "stalwart-mcp";
    };
  };

  # The password is read only from the environment (password_env), never
  # from the TOML: the config file can therefore live in /nix/store.
  configFile = pkgs.writeText "stalwart-mcp-config.toml" ''
    [[accounts]]
    name = "marc"
    url = "https://mail.vps.marcpartensky.com"
    # Stalwart authenticates the PRINCIPAL ("marc"), not the email address.
    username = "marc"
    password_env = "STALWART_PASSWORD"

    [capabilities]
    # mail_send / mail_draft / mail_flag / mail_move enabled.
    send = true

    [notifications]
    # No permanent SSE stream: useless for a stdio client driven by hermes.
    enabled = false
  '';

  # The sops secret is a file; the server expects an env variable.
  # The wrapper avoids copying the password into config.yaml or the store.
  wrapper = pkgs.writeShellScriptBin "stalwart-mcp-hermes" ''
    set -eu
    STALWART_PASSWORD="$(cat ${config.sops.secrets."stalwart-mcp/password".path})"
    export STALWART_PASSWORD
    exec ${stalwart-mcp}/bin/stalwart-mcp -c ${configFile} "$@"
  '';
in {
  # Secret dedicated to the MCP, encrypted for tower only (cf. secrets/stalwart-mcp.yml).
  # It contains the same password as stalwart_mail_password on the VPS,
  # but tower cannot decrypt anywhere.yml.
  sops.secrets."stalwart-mcp/password" = {
    sopsFile = ../../secrets/stalwart-mcp.yml;
    key = "stalwart_mcp_password";
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  services.hermes-agent.mcpServers.stalwart = {
    command = "${wrapper}/bin/stalwart-mcp-hermes";
    args = [ "serve" ];
    timeout = 60;
  };
}
