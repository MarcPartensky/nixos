{
  config,
  pkgs,
  inputs,
  ...
}: let
  # ATTENTION : les paquets python pour hermes DOIVENT venir de la nixpkgs du
  # flake hermes-agent (même python 3.12.13 que le venv scellé). Avec la nixpkgs
  # système, hasPythonModule les filtre silencieusement -> PYTHONPATH sans le paquet.
  hermesPkgs = inputs.hermes-agent.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in {
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

    # venv nix scellé -> deps mem0 (mem0ai) installées au runtime dans une cible durable
    environment.HERMES_LAZY_INSTALL_TARGET = "/var/lib/hermes/.hermes/lazy-python";

    # psycopg2 buildé par nix (évite le wheel manylinux psycopg2-binary)
    # NB: withPackages est filtré par hasPythonModule (pas d'attr pythonModule)
    # numpy : les wheels manylinux cassent sur NixOS (libstdc++.so.6 absent) —
    # les deps compilées des lazy-installs doivent venir de nix
    extraPythonPackages = with hermesPkgs.python312Packages; [ psycopg2 numpy ];

    # claude-code CLI sur le PATH du service : requis par le plugin officiel
    # claude-subscription-directsdk (provider sur abonnement Claude Pro/Max,
    # login OAuth via `claude`, pas de clé API)
    extraPackages = [pkgs.claude-code];
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

      # --- Modèle par défaut : abonnement Claude Pro de marc via le plugin ---
      # claude-subscription-directsdk (CLI claude en OAuth, quota Agent SDK).
      # kimi reste déclaré ci-dessus en provider secondaire (custom:kimi-k3-global).
      model = {
        provider = "claude-subscription-directsdk-experimental";
        default = "claude-sonnet-5";
        context_length = 1000000;
        supports_vision = true;
      };

      # --- Chaîne de secours si le primaire tombe (rate limit, 5xx, auth) ---
      # essayés dans l'ordre, Bascule au milieu de session sans perdre la conv.
      # inkling:free (1M ctx, Thinking Machines, uptime ~99.9%) puis
      # nemotron 3 ultra:free (1M ctx, Nvidia, uptime ~99%). Clé: OPENROUTER_API_KEY
      # (déjà dans l'env du service). Vérifié le 24/09/2026 : 1000 req/jour
      # autorisées sur les variantes :free de cette clé, 0 utilisées.
      fallback_providers = [
        {
          provider = "openrouter";
          model = "thinkingmachines/inkling:free";
        }
        {
          provider = "openrouter";
          model = "nvidia/nemotron-3-ultra-550b-a55b:free";
        }
      ];

      agent = {
        reasoning_effort = "max";
      };

      # --- Coût estimé dans la status bar CLI/TUI ---
      display = {
        show_cost = true;
      };

      auxiliary = {
        # vision : reste sur kimi explicitement (ne pas taper dans le quota
        # Claude Pro pour les descriptions d'images)
        vision = {
          provider = "custom:kimi-k3-global";
          model = "kimi-k3";
          extra_body = {
            reasoning_effort = "max";
          };
        };
      };
    };
  };

  # --- ollama : embeddings locaux pour mem0 (pas de clé OpenAI) ---
  # nomic-embed-text = 768 dims, supporté par le plugin mem0. CPU suffit.
  services.ollama = {
    enable = true;
    loadModels = ["nomic-embed-text"];
  };

  # claude aussi dispo pour marc et les sessions CLI de hermes
  environment.systemPackages = [pkgs.claude-code];

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

  # --- MCP Nextcloud : voir services/nextcloud-mcp (single_user_basic, loopback) ---
}
