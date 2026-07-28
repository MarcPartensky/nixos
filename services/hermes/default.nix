{ config, ... }:
{
  # --- Déclaration des besoins PostgreSQL ---
  # NixOS fusionne automatiquement ces listes avec celles du module postgres
  services.postgresql.ensureDatabases = [ "hermes" ];
  services.postgresql.ensureUsers = [
    {
      name = "hermes";
      ensureDBOwnership = true; # hermes devient owner de la DB "hermes"
    }
  ];

  # --- Service Hermes ---
  services.hermes-agent = {
    enable = true;
    settings.model.default = "anthropic/claude-sonnet-4";
    environmentFiles = [ config.sops.secrets."hermes_env".path ];
    addToSystemPackages = true;
  };

  sops.secrets."hermes_env" = { };
}
