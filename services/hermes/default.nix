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
      # --- Provider custom Kimi/Moonshot ---
      custom_providers = [
        {
          name = "kimi-k3-global";
          base_url = "https://api.moonshot.ai/v1";
          key_env = "KIMI_API_KEY"; # <- la var d'env qui porte ta clé
          api_mode = "chat_completions";
          model = "kimi-k3";
          extra_body = {
            reasoning_effort = "max";
          };
          models = {
            kimi-k3 = {
              context_length = 1048576;
              supports_vision = true;
            };
          };
        }
      ];

      # --- Modèle par défaut : pointe vers le provider custom ---
      model = {
        provider = "custom:kimi-k3-global"; # <- plus "openrouter"
        default = "kimi-k3";
        context_length = 1048576;
        supports_vision = true;
      };

      agent = {
        reasoning_effort = "max";
      };

      # --- Coût estimé dans la status bar CLI/TUI ---
      display = {
        show_cost = true;
      };

      auxiliary = {
        vision = {
          provider = "main";
          model = "kimi-k3";
          extra_body = {
            reasoning_effort = "max";
          };
        };
      };
    };
    #   mcpServers.beeper = {
    #     url = "http://localhost:23373/v0/mcp";
    #     headers.Authorization = "Bearer \${BEEPER_ACCESS_TOKEN}";
    #   };
    # mcpServers.nextcloud.url = "http://127.0.0.1:8710/mcp";
  };

  sops.secrets."hermes_env" = {};

  security.sudo.extraRules = [
    {
      users = ["marc" "hermes"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
        {
          command = "/nix/store/*-nixos-rebuild/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # --- git : nixos-rebuild s'exécute en root même lancé par hermes ---
  # sans ça, libgit2 refuse d'ouvrir un flake appartenant à marc
  programs.git = {
    enable = true;
    config.safe.directory = ["/home/marc/git/nixos"];
  };

  systemd.tmpfiles.rules = [
    "a /home/marc - - - - u:hermes:--x,m::--x"
    "a /home/marc/git - - - - u:hermes:--x,m::r-x"
  ];

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
