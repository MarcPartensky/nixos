# services/stalwart-mcp/default.nix
# Serveur MCP pour Stalwart Mail Server (webpatser/stalwart-mcp), en Rust.
# Parle JMAP à https://mail.vps.marcpartensky.com (Traefik -> 127.0.0.1:8390
# sur le VPS) : aucune ouverture de port supplémentaire, aucun mail ne transite
# par un tiers. Transport stdio : hermes spawn le binaire en subprocess.
#
# Le binaire upstream n'a PAS de Cargo.lock : celui du dépôt a été généré
# depuis le commit épinglé dans flake.nix (cargo generate-lockfile) et doit
# être régénéré à chaque bump de l'input. Sans lui, buildRustPackage échoue
# (fetch-cargo-vendor exige un lock).
{ pkgs, inputs, config, lib, ... }: let
  stalwart-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "stalwart-mcp";
    version = "0.1.0-unstable-2026-04-14";
    # L'upstream n'a pas de Cargo.lock : on l'injecte dans la source pour que
    # le hook cargo le trouve (et pour figer les versions résolues).
    src = pkgs.runCommandLocal "stalwart-mcp-source" {} ''
      cp -r ${inputs.stalwart-mcp} $out
      chmod -R u+w $out
      cp ${./Cargo.lock} $out/Cargo.lock
    '';
    cargoHash = "sha256-JVuPj9UTA+77JCeVKRZTBbYOxe8l7KmcyyayfxR0VDc=";
    # Stalwart 0.15 annonce son adresse de bind (mx1:8390) dans apiUrl quand il
    # est derrière un reverse proxy ; le client JMAP suit cette URL et échoue.
    # Le patch garde le chemin annoncé mais réutilise l'origine configurée.
    preBuild = ''
      patch -p1 -d ../$name-vendor/source-registry-0/jmap-client-0.4.3 < ${./jmap-api-url.patch}
      patch -p1 < ${./send-from-identity.patch}
    '';
    meta = {
      description = "Rust MCP server for Stalwart Mail Server — AI mail access via JMAP";
      homepage = "https://github.com/webpatser/stalwart-mcp";
      license = lib.licenses.agpl3Only;
      mainProgram = "stalwart-mcp";
    };
  };

  # Le mot de passe n'est lu que depuis l'environnement (password_env), jamais
  # depuis le TOML : le fichier de config peut donc vivre dans le /nix/store.
  configFile = pkgs.writeText "stalwart-mcp-config.toml" ''
    [[accounts]]
    name = "marc"
    url = "https://mail.vps.marcpartensky.com"
    # Stalwart authentifie le PRINCIPAL ("marc"), pas l'adresse email.
    username = "marc"
    password_env = "STALWART_PASSWORD"

    [capabilities]
    # mail_send / mail_draft / mail_flag / mail_move activés.
    send = true

    [notifications]
    # Pas de flux SSE permanent : inutile pour un client stdio piloté par hermes.
    enabled = false
  '';

  # Le secret sops est un fichier ; le serveur attend une variable d'env.
  # Le wrapper évite de recopier le mot de passe dans config.yaml ou dans le store.
  wrapper = pkgs.writeShellScriptBin "stalwart-mcp-hermes" ''
    set -eu
    STALWART_PASSWORD="$(cat ${config.sops.secrets."stalwart-mcp/password".path})"
    export STALWART_PASSWORD
    exec ${stalwart-mcp}/bin/stalwart-mcp -c ${configFile} "$@"
  '';
in {
  # Secret dédié au MCP, chiffré pour tower uniquement (cf. secrets/stalwart-mcp.yml).
  # Il contient le même mot de passe que stalwart_mail_password sur le VPS,
  # mais tower ne peut pas déchiffrer anywhere.yml.
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
