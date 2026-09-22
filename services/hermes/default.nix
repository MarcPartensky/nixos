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
    environmentFiles = [config.sops.secrets."hermes_env".path];
    addToSystemPackages = true;
    # extraDependencyGroups = ["anthropic"];
    # settings.model = {
    #   base_url = "https://api.anthropic.com/v1";
    #   default = "anthropic/claude-sonnet-4";
    # };
    settings = {
      model = {
        # Kimi via API directe Moonshot
        default = "moonshot/kimi-latest"; # ou simplement "kimi-latest" selon version
        base_url = "https://api.moonshot.cn/v1";
      };
    };
    #   mcpServers.beeper = {
    #     url = "http://localhost:23373/v0/mcp";
    #     headers.Authorization = "Bearer \${BEEPER_ACCESS_TOKEN}";
    #   };
    # mcpServers.nextcloud.url = "http://127.0.0.1:8710/mcp";
  };

  sops.secrets."hermes_env" = {};

  # --- MCP Nextcloud : calendrier uniquement, loopback uniquement ---
  # virtualisation.oci-containers.containers.nextcloud-mcp = {
  #   image = "ghcr.io/cbcoutinho/nextcloud-mcp-server:latest"; # épingle un tag une fois validé
  #   cmd = ["--enable-app" "calendar"];
  #   ports = ["127.0.0.1:8710:8000"];
  #   environment.NEXTCLOUD_HOST = "https://cloud.vps.marcpartensky.com";
  #   environmentFiles = [config.sops.secrets."nextcloud_mcp_env".path];
  # };

  # sops.secrets."nextcloud_mcp_env" = {};
}
