# services/stalwart-mcp/default.nix
# Rust MCP server pour Stalwart Mail Server (webpatser/stalwart-mcp).
# Expose les outils mail via JMAP (lecture, recherche, notifications temps réel).
# Transport stdio : hermes spawn le binaire en subprocess.
# Compte utilisé : "marc" (déjà créé dans services/stalwart/default.nix).
# JMAP endpoint : https://mail.vps.marcpartensky.com (Traefik -> 127.0.0.1:8390).
{ pkgs, inputs, config, lib, ... }: let
  # Build depuis le repo GitHub (Rust, Cargo.toml) via flake input
  stalwart-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "stalwart-mcp";
    version = "0.1.0";
    src = inputs.stalwart-mcp;
    # Hash SRI du dossier vendor/ calculé localement (recursive hash)
    cargoHash = "sha256-3eMzoPZPO0S9D3Z0Tkkz894QHygU/osMFDTYQ6S+F04=";
    meta = {
      description = "Rust MCP server for Stalwart Mail Server — AI mail access via JMAP";
      homepage = "https://github.com/webpatser/stalwart-mcp";
      license = lib.licenses.mit;
      mainProgram = "stalwart-mcp";
    };
  };

  # Config file pour stalwart-mcp (TOML), injecté via variable d'env
  configContent = ''
    [[accounts]]
    name = "marc"
    url = "https://mail.vps.marcpartensky.com"
    username = "marc@marcpartensky.com"
    secret = "${config.sops.secrets.\"stalwart/mail_pw2\".path}"
  '';
in {
  # Référence le secret existant dans secrets/common.yml (clé stalwart_mail_pw2)
  sops.secrets."stalwart/mail_pw2" = {
    sopsFile = ../../secrets/common.yml;
    key = "stalwart_mail_pw2";
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  # Écrit le fichier de config dans un endroit lisible par hermes
  environment.etc."stalwart-mcp/config.toml".text = configContent;

  services.hermes-agent.mcpServers.stalwart = {
    command = "${stalwart-mcp}/bin/stalwart-mcp";
    env = {
      STALWART_MCP_CONFIG = "/etc/stalwart-mcp/config.toml";
      MCP_TRANSPORT = "stdio";
    };
    timeout = 60;
  };
}