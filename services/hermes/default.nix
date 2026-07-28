{ config, ... }:
{
  services.hermes-agent = {
    enable = true;
    settings.model.default = "anthropic/claude-sonnet-4";
    environmentFiles = [ config.sops.secrets."hermes_env".path ];
    addToSystemPackages = true;
  };

  sops.secrets."hermes_env" = { };
}
