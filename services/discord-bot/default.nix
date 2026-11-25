{
  inputs,
  config,
  lib,
  ...
}: {
  imports = [inputs.discord-bot.nixosModules.default];
  users.users.discord-bot = {
    isSystemUser = true;
    group = "discord-bot";
  };
  users.groups.discord-bot = {};

  services.discord-bot = {
    enable = true;
    environmentFile = config.sops.secrets."discord_bot_env".path;
    host = "127.0.0.1";
    port = 8050;
  };

  # Bridge to the Hermes API server. A single listener per host: the gateway of
  # the default profile serves all profiles, that of a secondary profile under
  # /p/<profile>/ (see services/hermes). It is THIS route that the cog consumes,
  # not a dedicated port: it only listens if the gateway is running (8642).
  # HERMES_BRIDGE_URL is not secret (local loopback), only the key is.
  systemd.services.discord-bot.serviceConfig.EnvironmentFile = lib.mkAfter [
    config.sops.secrets."discord_bot_hermes_bridge_env".path
  ];
  systemd.services.discord-bot.environment = {
    HERMES_BRIDGE_URL = "http://127.0.0.1:8642/p/discord-bridge/v1/chat/completions";
    HERMES_BRIDGE_ROLE_NAME = "hermes";
    # Local test surface of the cog (loopback, NOT opened in the firewall):
    # POST /hermes/ask {"message": "..."} -> {"answer": "..."}.
    HERMES_BRIDGE_ASK_PORT = "8052";
  };

  sops.secrets."discord_bot_env" = {};
  sops.secrets."discord_bot_hermes_bridge_env" = {
    sopsFile = ../../secrets/discord-hermes-bridge.yml;
    owner = "discord-bot";
    group = "discord-bot";
  };
}
