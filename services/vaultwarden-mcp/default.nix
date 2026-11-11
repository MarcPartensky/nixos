# services/vaultwarden-mcp/default.nix
# Serveur MCP Vaultwarden (jr2804/vaultwarden-mcp) : binaire Rust, stdio.
# Binaire téléchargé depuis GitHub releases (plus simple que crate2nix).
#
# PÉRIMÈTRE (décision marc, 10/11/2026) : ce serveur pointe sur le compte
# TECHNIQUE hermes@marcpartensky.com, pas sur le compte de marc. Le mot de
# passe maître de ce compte vit dans secrets/vaultwarden-agent.yml (âge vers
# la seule clé de tower) parce qu'il faut l'ouvrir sans intervention humaine.
# La séparation est donc de PRIVILÈGE, pas de surface : elle garantit que le
# navigateur piloté en CDP ne voit jamais le coffre principal, elle ne protège
# pas contre une compromission de tower.
#
# RÈGLE DE CONTENU : ce coffre ne reçoit que des capacités révocables ou sans
# pouvoir financier (portails en lecture, comptes d'outils, API révocables).
# JAMAIS : IBKR, Caisse d'Épargne, Chase, Wise, Bangkok Bank, la messagerie
# (pivot de réinitialisation), le code de récupération du coffre principal,
# ni les graines 2FA.
#
# Le compte a été créé via POST /identity/accounts/register (crypto cliente
# PBKDF2 600k + HKDF-Expand enc/mac, RSA 2048, EncString type 2), puis la
# dérivation a été VÉRIFIÉE en se connectant avec le CLI officiel `bw login`
# (2026.4.2) : c'est ce test qui prouve que le compte est utilisable par un
# client officiel et pas seulement par le script de création.
#
# Aucun pouvoir de passer un ordre ou de virer de l'argent : le coffre ne sert
# qu'à restituer des identifiants de connexion.
{
  pkgs,
  lib,
  config,
  ...
}: let
  vaultwarden-mcp-bin = pkgs.stdenv.mkDerivation {
    pname = "vaultwarden-mcp";
    version = "0.1.0";
    src = pkgs.fetchurl {
      url = "https://github.com/jr2804/vaultwarden-mcp/releases/latest/download/vaultwarden-mcp-linux-x86_64";
      # Vérifié le 10/11/2026 : le binaire servi par `latest` donne bien ce hash
      # (sha256 hex cb8eff7a2678dd03b8661eac79ca4f7a677e86be17ff16323bc53318b8497fc4).
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

  # Wrapper : le secret est lu AU LANCEMENT depuis le fichier sops (comme
  # wise-mcp), donc il n'apparaît ni dans la closure nix ni dans un fichier
  # d'environnement lisible par tous.
  wrapper = pkgs.writeShellScript "vaultwarden-mcp-hermes" ''
    set -euo pipefail
    export VAULTWARDEN_SERVER="https://vault.marcpartensky.com"
    export VAULTWARDEN_PASSWORD="$(cat ${config.sops.secrets."vaultwarden/agent_password".path})"
    export RUST_LOG=info
    exec ${vaultwarden-mcp-bin}/bin/vaultwarden-mcp serve --transport stdio
  '';
in {
  environment.systemPackages = [vaultwarden-mcp-bin];

  sops.secrets."vaultwarden/agent_password" = {
    key = "vaultwarden_agent_password";
    sopsFile = ../../secrets/vaultwarden-agent.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  services.hermes-agent.mcpServers.vaultwarden = {
    command = "${wrapper}";
    timeout = 180;
  };
}
