# services/discord-hermes-bridge/default.nix
#
# Dedicated Hermes gateway, profile "discord-bridge" (created by hand on tower via
# `hermes profile create discord-bridge`, same mechanics as the pocket profile:
# no notion of "instances" in the NixOS module services.hermes-agent,
# so systemd unit written by hand here rather than via that option).
#
# Reuses the SAME hermes-agent package (config.services.hermes-agent.package)
# as the Matrix bot @hermes in services/hermes: same build, so the same
# groups of optional deps (edge-tts, stt-whisper...) are already present,
# useful for phase 2 (voice) of the Discord bridge without extra work.
#
# Exposes only the OpenAI-compatible API Server (/v1/chat/completions) on
# loopback, consumed by the hermes.py cog of the bot (services/discord-bot).
# Never a port open to the firewall: it is the same host, same loopback.
{
  config,
  lib,
  ...
}: let
  package = config.services.hermes-agent.package;
  port = 8643;
in {
  sops.secrets."hermes_discord_bridge_env" = {
    sopsFile = ../../secrets/discord-hermes-bridge.yml;
    owner = "hermes";
    group = "hermes";
  };

  systemd.services.hermes-discord-bridge = {
    description = "Dedicated Hermes Agent gateway (discord-bridge profile, bridge to discord-bot)";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
      HERMES_MANAGED = "true";
      # API_SERVER_ENABLED/PORT/KEY are the only documented variables
      # (no API_SERVER_HOST: the 127.0.0.1 loopback bind is the default,
      # not configurable). API_SERVER_KEY comes from the sops file (EnvironmentFile).
      API_SERVER_ENABLED = "true";
      API_SERVER_PORT = toString port;
    };

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${package}/bin/hermes -p discord-bridge gateway";
      EnvironmentFile = [config.sops.secrets."hermes_discord_bridge_env".path];
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = false;
      ProtectSystem = "strict";
      ReadWritePaths = ["/var/lib/hermes"];
      UMask = "0007";
      WorkingDirectory = "/var/lib/hermes/workspace";
    };
  };

  assertions = [
    {
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "discord-hermes-bridge: port ${toString port} (local API server) must not be open to the firewall.";
    }
  ];
}
