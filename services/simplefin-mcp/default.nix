# services/simplefin-mcp/default.nix
# SimpleFIN MCP server (read-only) for hermes: accounts and transactions
# Chase via the SimpleFIN Bridge, stdio transport. 5 tools: status,
# list_accounts, get_transactions, search_transactions, spending_summary.
#
# Credential: the Bridge access URL (Basic credentials embedded), in
# secrets/simplefin.yml (key simplefin_access_url). It is obtained by
# claiming a Setup Token (single use):
#   python3 /var/lib/hermes/.hermes/scripts/simplefin_claim.py <token>
# then re-encrypting this sops file from the plaintext (tower public key
# only, no private key required):
#   cd /home/marc/git/nixos
#   printf 'simplefin_access_url: "%s"\n' \
#     "$(cat /var/lib/hermes/.hermes/simplefin-access-url)" > /tmp/plain.yml
#   sops -e --filename-override secrets/simplefin.yml /tmp/plain.yml \
#     > secrets/simplefin.yml
#   shred -u /tmp/plain.yml
#
# Bridge limits: 24 requests/day, 90-day max window, read-only,
# 15 USD/year subscription to be paid, otherwise /accounts responds 402 "Payment
# required" (the status tool says so explicitly).
#
# The server re-reads the secret file ON EVERY call (nothing in the closure env
# nor in the store): a rotation of the access URL requires no
# restart of hermes.
{pkgs, config, ...}: let
  simplefin-mcp =
    pkgs.writers.writePython3Bin "simplefin-mcp" {
      libraries = [pkgs.python3Packages.mcp];
      flakeIgnore = ["E501" "W503" "W504"];
    } (builtins.readFile ./simplefin_mcp.py);
in {
  sops.secrets.simplefin_access_url = {
    sopsFile = ../../secrets/simplefin.yml;
    owner = "hermes";
    mode = "0400";
  };

  # On the PATH to probe the server by hand (stdio).
  environment.systemPackages = [simplefin-mcp];

  services.hermes-agent.mcpServers.simplefin = {
    command = "${simplefin-mcp}/bin/simplefin-mcp";
    env.SIMPLEFIN_ACCESS_URL_FILE = config.sops.secrets.simplefin_access_url.path;
    timeout = 120;
  };
}
