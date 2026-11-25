# services/hermes-browser/bitwarden.nix
# Bitwarden CLI (`bw`) for the hermes user: Hermes detects it on its own
# on its PATH (/etc/profiles/per-user/hermes/bin) and uses it as the "bitwarden"
# backend of browser_vault. The master password never passes
# through the conversation: Hermes asks for it in a masked prompt (bw unlock
# --passwordenv), the session token stays in memory.
#
# - Server: https://vault.marcpartensky.com (tower's Vaultwarden). The 2026
#   CLI refuses any http server, so no direct 127.0.0.1:8222;
#   the API must be reachable without the Pangolin SSO (bypass rules
#   on /api, /identity, /notifications of the Pangolin resource).
# - Initial login, only once, by marc: `sudo -u hermes bw login`.
# - users.users.hermes.packages rather than environment.systemPackages: tool
#   specific to the agent, and the addition does not restart hermes-agent.
{
  pkgs,
  ...
}: let
  server = "https://vault.marcpartensky.com";
  bw = "${pkgs.bitwarden-cli}/bin/bw";
in {
  users.users.hermes.packages = [pkgs.bitwarden-cli];

  # Points the CLI at the right server as long as no account is connected
  # (bw refuses to change server once logged in). Idempotent.
  systemd.services.hermes-bw-server = {
    description = "hermes bw CLI pointed at ${server}";
    wantedBy = ["multi-user.target"];
    environment.HOME = "/var/lib/hermes";
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      RemainAfterExit = true;
    };
    script = ''
      status=$(${bw} status 2>/dev/null || true)
      cur=$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -r '.serverUrl // empty' 2>/dev/null || true)
      st=$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -r '.status // empty' 2>/dev/null || true)
      if [ "$cur" != "${server}" ] && [ "$st" != "locked" ] && [ "$st" != "unlocked" ]; then
        ${bw} config server "${server}" >/dev/null 2>&1 || true
      fi
    '';
  };
}
