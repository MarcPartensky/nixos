# Entry point of the LAPTOP's NixOS services.
#
# The laptop no longer imports the ./services monolith: the latter carries
# about sixty tower-specific modules (Zitadel, Gitea, Immich, Matrix, banking,
# IBKR...) many of which declare sops secrets that the laptop is not
# a recipient of. Consequence measured on 20/11/2026: the laptop declared 18
# sops files (34 secrets) it could not decrypt, 17 of them without its
# age key. The sops manifest then refuses to build and the WHOLE build
# fails, even for the valid secrets (see skill sops-nix-secrets, rule 1).
#
# What the laptop really needs:
#   - tailscale: it is already enrolled in headscale, so with no pre-auth key
#     (secrets/headscale.yml does not list it);
#   - hermes: the fallback gateway, installed but stopped at boot;
#   - hermes-fallback: state copy from tower + automatic failover.
#
# What it already imports directly in profiles/laptop: tts-mcp, llm-server,
# immich-ml, backup-pqbox, disko and hardware.
{...}: {
  imports = [
    ./tailscale
    ./hermes
    ./hermes-fallback
  ];

  # Node already registered in headscale: no pre-authentication key.
  meshTailscale.enablePreauthKey = false;

  # No Gitea MCP server (secret secrets/gitea-mcp.yml, tower only).
  services.hermes.enableGiteaMcp = false;
}