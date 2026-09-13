{
  inputs,
  config,
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

  sops.secrets."discord_bot_env" = {};
}
