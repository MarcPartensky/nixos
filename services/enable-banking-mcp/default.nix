# services/enable-banking-mcp/default.nix
# Enable Banking MCP server (PSD2 AIS, read-only) for hermes:
# accounts, balances and transactions of European banks (Caisse
# d'Epargne via BPCE, SCA Banxo), stdio transport. 8 tools: status,
# list_institutions, connection_create, session_create/get/delete,
# account_details/balances/transactions.
#
# Credential: JSON {"app_id", "private_key"} of the app registered at the
# panel https://enablebanking.com/cp (PRODUCTION environment, mode
# restricted by linked accounts = free for personal use). The
# private key was generated here (openssl 4096); the public certificate to
# download is the one uploaded when registering the app. Re-read on
# each call via ENABLE_BANKING_APP_FILE: no rotation requires
# a restart of hermes.
#
# TODO(marc): app_id still PLACEHOLDER -- the server is deployed but
# INERT (status says so explicitly) as long as the app is not
# registered at the panel. When the app_id arrives, RECREATE the sops
# file (delete + re-encrypt from the public keys, no private key
# required):
#   cd /home/marc/git/nixos
#   python3 - <<'PY'
#   import json
#   key = open("/var/lib/hermes/.hermes/cache/scratch/eb/private.key").read()
#   print("app: " + json.dumps({"app_id": "<APP_ID>", "private_key": key}))
#   PY > /tmp/eb-plain.yml
#   nix run nixpkgs#sops -- -e --filename-override secrets/enable-banking.yml \
#     --output secrets/enable-banking.yml /tmp/eb-plain.yml
#   shred -u /tmp/eb-plain.yml
#
# Constraints: JWT RS256 to sign per call (done in the server, TTL
# 1 h); consent ~90-180 days then re-link; only the restricted app
# reads the accounts it has linked.
{
  pkgs,
  config,
  ...
}:
let
  enable-banking-mcp = pkgs.writers.writePython3Bin "enable-banking-mcp"
    {
      libraries = [
        pkgs.python3Packages.mcp
        pkgs.python3Packages.cryptography
      ];
    } (builtins.readFile ./enable_banking_mcp.py);
in
{
  services.hermes-agent.mcpServers.enable-banking = {
    command = "${enable-banking-mcp}/bin/enable-banking-mcp";
    env.ENABLE_BANKING_APP_FILE =
      config.sops.secrets.enable_banking_app.path;
    timeout = 120;
  };

  sops.secrets.enable_banking_app = {
    sopsFile = ../../secrets/enable-banking.yml;
    key = "app";
    owner = "hermes";
    mode = "0400";
  };

  # On the PATH to probe the server by hand (stdio).
  environment.systemPackages = [ enable-banking-mcp ];
}
