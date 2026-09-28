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

  # Pont vers l'API server Hermes. Un seul listener par hôte (le profil default,
  # cf. services/hermes) : un profil secondaire est servi sous /p/<profil>/.
  # HERMES_BRIDGE_URL n'est pas secret (loopback local), seule la clé l'est.
  systemd.services.discord-bot.serviceConfig.EnvironmentFile = lib.mkAfter [
    config.sops.secrets."discord_bot_hermes_bridge_env".path
  ];
  systemd.services.discord-bot.environment = {
    HERMES_BRIDGE_URL = "http://127.0.0.1:8643/v1/chat/completions";
    HERMES_BRIDGE_ROLE_NAME = "hermes";
    # Surface de test locale du cog (loopback, PAS ouverte au firewall) :
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
