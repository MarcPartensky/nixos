# services/thclaws/default.nix
#
# thClaws: agent harness in Rust (GUI + CLI + webapp from a single binary).
# The package comes from the project flake /home/marc/git/thclaws (prebuilt binary
# repackaged with autoPatchelf); here we only declare the service.
#
# EXPOSURE (selfhosted-remote-access skill): thClaws has NO
# authentication of its own. Measurement on 13/11/2026 of 0.156.0: `GET /` returns
# 200 without a token, even with THCLAWS_SERVE_TOKEN set in the environment. The UI
# gives full bash access, so:
#   - port 8453 is NOT in networking.firewall.allowedTCPPorts: the LAN
#     (wlan0) is closed, only the trusted interfaces (tailscale0, ygg, lo)
#     pass;
#   - public access goes through Pangolin with SSO (resource `thclaws` in
#     services/newt): it is Pangolin that carries the Zitadel OIDC, not thClaws;
#   - the tailnet is the direct path, without application auth (WireGuard
#     identity). This is a deliberate choice: whoever is on the tailnet drives
#     the agent.
#
# Postgres: not applicable. thClaws has no database, its state is on disk
# (.thclaws/ in the root directory: JSONL sessions, settings, KMS). The
# StateDirectory /var/lib/thclaws is therefore the only persistence to back up.
{
  config,
  pkgs,
  lib,
  ...
}: let
  # PURE EVAL: the package must come from the repo, not from an absolute path outside the
  # flake (a `callPackage /home/marc/git/thclaws/package.nix` breaks pure eval
  # with "cannot access absolute path"). ./package.nix is a synchronized copy
  # of the project flake, cf the header of this file.
  thclaws = pkgs.callPackage ./package.nix { };

  envFile = "/run/thclaws/env";
  port = 8453;
in {
  # thClaws reads its keys either from the OS keychain (absent in headless), or from
  # environment variables. We extract only marc's three providers from
  # hermes's .env (same mechanism as winnie-ingest-env): nothing
  # sensitive goes into the store, and the file stays at 0640 under /run.
  systemd.services.thclaws-env = {
    description = "Extract provider keys for thClaws";
    wantedBy = ["multi-user.target"];
    before = ["thclaws.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -e
      install -d -m 0750 -o hermes -g hermes /run/thclaws
      umask 0027
      : > ${envFile}
      for key in DEEPSEEK_API_KEY OPENROUTER_API_KEY KIMI_API_KEY; do
        ${pkgs.gnugrep}/bin/grep -E "^''${key}=" /var/lib/hermes/.hermes/.env >> ${envFile} || true
      done
      chown hermes:hermes ${envFile}
      chmod 0640 ${envFile}
    '';
  };

  systemd.services.thclaws = {
    description = "thClaws agent harness (webapp)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "thclaws-env.service"];
    wants = ["network-online.target" "thclaws-env.service"];

    environment = {
      # Behind the authenticating reverse proxy (Pangolin/badger): this is the
      # mode intended by upstream for this setup.
      THCLAWS_SERVE_BEHIND_PROXY = "1";
      THCLAWS_EXTERNAL_URL = "https://thclaws.marcpartensky.com";
    };

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      # Root of the agent's file sandbox (ch.3 of the manual: all the
      # read/write/edit/bash tools are confined to this directory).
      StateDirectory = "thclaws";
      StateDirectoryMode = "0750";
      WorkingDirectory = "/var/lib/thclaws";
      EnvironmentFile = envFile;
      # StateDirectory creates /var/lib/thclaws, but systemd resolves
      # WorkingDirectory at the moment of chdir: we create it explicitly beforehand.
      ExecStartPre = "+${pkgs.coreutils}/bin/mkdir -p /var/lib/thclaws";
      ExecStart = "${thclaws}/bin/thclaws --serve --port ${toString port} --bind 0.0.0.0";
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
      KillMode = "mixed";

      # The agent must be able to launch marc's system commands (including
      # `sudo nixos-rebuild`, NOPASSWD on hermes side): no NoNewPrivileges.
      NoNewPrivileges = false;
      PrivateTmp = true;
      ProtectHome = false;
      ProtectSystem = false;
    };
  };
}
