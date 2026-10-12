# services/vaultwarden-mcp/default.nix
# Serveur MCP Vaultwarden (jr2804/vaultwarden-mcp) : binaire Rust, stdio.
# Binaire téléchargé depuis GitHub releases (plus simple que crate2nix).
#
# Authentification : VAULTWARDEN_SERVER + VAULTWARDEN_PASSWORD (master password).
# Les identifiants sont gérés via sops.
#
# Fichier créé à la demande de Marc (27/09/2026).
# IMPORTANT : il faut ajouter `vaultwarden_mcp_password` dans secrets/tower.yml
# avant activation :
#   sops secrets/tower.yml    # ajouter la clé vaultwarden_mcp_password
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  # Binaire téléchargé depuis GitHub releases
  vaultwarden-mcp-bin = pkgs.stdenv.mkDerivation {
    pname = "vaultwarden-mcp";
    version = "0.1.0";
    src = pkgs.fetchurl {
      url = "https://github.com/jr2804/vaultwarden-mcp/releases/latest/download/vaultwarden-mcp-linux-x86_64";
      sha256 = "sha256-y47/eiZ43QO4Zh6secpPemd+hr4X/xYyO8UzGLhJf8Q=";
    };
    dontUnpack = true;
    installPhase = ''
      install -D $src $out/bin/vaultwarden-mcp
      chmod +x $out/bin/vaultwarden-mcp
    '';
    meta = {
      description = "MCP server for Vaultwarden vault access";
      homepage = "https://github.com/jr2804/vaultwarden-mcp";
      license = lib.licenses.mit;
    };
  };
in {
  # Le binaire est disponible sur le PATH du système.
  environment.systemPackages = [vaultwarden-mcp-bin];

  # Secret sops pour le mot de passe master Vaultwarden (défini dans secrets/tower.yml).
  sops.secrets."vaultwarden/mcp_password" = {
    key = "vaultwarden_mcp_password";
    sopsFile = ../../secrets/tower.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  # Intégration dans le service hermes-agent : serveur MCP stdio.
  services.hermes-agent.mcpServers.vaultwarden = {
    command = "${vaultwarden-mcp-bin}/bin/vaultwarden-mcp";
    args = ["serve" "--transport" "stdio"];
    env = {
      VAULTWARDEN_SERVER = "https://vault.marcpartensky.com";
      VAULTWARDEN_PASSWORD = config.sops.placeholder."vaultwarden/mcp_password";
      RUST_LOG = "info";
    };
    timeout = 180;
  };

  # Note : le service Vaultwarden existant (services/vaultwarden/default.nix)
  # tourne déjà sur tower avec le domaine https://vault.marcpartensky.com,
  # le port 8222, et l'admin token dans secrets/common.yml.
}