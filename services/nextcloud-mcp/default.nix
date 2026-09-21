{...}: {
  virtualisation.oci-containers.containers.nextcloud-mcp-claude = {
    image = "ghcr.io/cbcoutinho/nextcloud-mcp-server:latest";
    cmd = ["--transport" "streamable-http" "--oauth" "--port" "8004" "--enable-app" "calendar"];
    ports = ["127.0.0.1:8004:8004"];
    environment = {
      MCP_DEPLOYMENT_MODE = "login_flow";
      NEXTCLOUD_HOST = "https://cloud.vps.marcpartensky.com";
      NEXTCLOUD_PUBLIC_ISSUER_URL = "https://cloud.vps.marcpartensky.com";
      NEXTCLOUD_MCP_SERVER_URL = "https://mcp.vps.marcpartensky.com";
      TOKEN_STORAGE_DB = "/app/data/tokens.db";
    };
    environmentFiles = [config.sops.secrets."nextcloud_mcp_oauth_env".path];
    volumes = ["nextcloud-mcp-claude:/app/data"];
  };
  sops.secrets."nextcloud_mcp_oauth_env" = {};
}
