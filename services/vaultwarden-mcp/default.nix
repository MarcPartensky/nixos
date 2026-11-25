# services/vaultwarden-mcp/default.nix
# Vaultwarden MCP server (jr2804/vaultwarden-mcp): Rust binary, stdio.
# Binary downloaded from GitHub releases (simpler than crate2nix).
#
# SCOPE (marc's decision, 10/11/2026): this server points to the
# TECHNICAL account hermes@marcpartensky.com, not marc's account. The master
# password of this account lives in secrets/vaultwarden-agent.yml (age toward
# tower's only key) because it must be opened without human intervention.
# The separation is therefore of PRIVILEGE, not of surface: it guarantees that the
# browser driven over CDP never sees the main vault, it does not protect
# against a compromise of tower.
#
# CONTENT RULE: this vault only receives revocable capabilities or ones without
# financial power (read-only portals, tool accounts, revocable APIs).
# NEVER: IBKR, Caisse d'Epargne, Chase, Wise, Bangkok Bank, the mail
# (reset pivot), the recovery code of the main vault,
# nor the 2FA seeds.
#
# The account was created via POST /identity/accounts/register (client crypto
# PBKDF2 600k + HKDF-Expand enc/mac, RSA 2048, EncString type 2), then the
# derivation was VERIFIED by logging in with the official CLI `bw login`
# (2026.4.2): it is this test that proves the account is usable by an
# official client and not only by the creation script.
#
# No power to place an order or to transfer money: the vault only serves
# to return login credentials.
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
      # Verified on 10/11/2026: the binary served by `latest` does give this hash
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

  # Wrapper: the secret is read AT STARTUP from the sops file (like
  # wise-mcp), so it appears neither in the nix closure nor in an
  # environment file readable by everyone.
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
