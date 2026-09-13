{config, ...}: {
  # --- déclaration des besoins postgresql ---
  # nixos fusionne automatiquement ces listes avec celles du module postgres
  services.postgresql.ensureDatabases = ["hermes"];
  services.postgresql.ensureUsers = [
    {
      name = "hermes";
    }
  ];

  # --- service hermes ---
  services.hermes-agent = {
    enable = true;
    settings.model.default = "anthropic/claude-sonnet-4";
    environmentFiles = [config.sops.secrets."hermes_env".path];
    addToSystemPackages = true;
    extraDependencyGroups = ["anthropic"];
    settings.model = {
      base_url = "https://api.anthropic.com/v1";
    };
  };

  sops.secrets."hermes_env" = {};
}
