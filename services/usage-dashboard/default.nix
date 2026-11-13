# services/usage-dashboard : dashboard d'usage LLM (OpenRouter + providers directs).
#
# Chaine : Pangolin (usage.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9141 (ce service).
# Depuis le tailnet, l'URL directe est http://100.64.0.3:9141 (pas de SSO :
# tailscale0 est deja une interface de confiance, cf. services/tailscale).
#
# Le service ne fait que LIRE : solde et usage OpenRouter, schema et requetes
# analytics (depense par modele / cle / jour), solde Moonshot, taux USD->EUR.
# Rien n'est ecrit sauf son propre cache de demarrage (StateDirectory).
#
# Deux cles OpenRouter, deux roles :
#   - openrouter_management_key : SEULE cle qui ouvre /api/v1/analytics, donc
#     seule source du detail par modele. Elle ne peut pas faire d'inference
#     (lecture seule, gratuite). A creer sur
#     https://openrouter.ai/settings/management-keys puis a ecrire dans
#     secrets/usage-dashboard.yml (voir la commande en commentaire plus bas).
#   - openrouter_inference_key : la cle qui sert reellement a hermes, pour
#     l'usage temps reel de la cle (/api/v1/key : jour / semaine / mois).
# Tant qu'une des deux est un placeholder, la page se deploie quand meme et
# affiche ce qu'elle peut, avec l'etat de chaque source dans son pied de page.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.usageDashboard;

  port = 9141;
  domain = "usage.marcpartensky.com";

  # Secrets : deux cles OpenRouter + la cle Moonshot (provider kimi direct).
  # Creation du fichier (l'age de tower chiffre, aucune cle privee requise) :
  #   cat > /tmp/usage-dashboard.yml <<'EOF'
  #   openrouter_management_key: PLACEHOLDER_REPLACE_WITH_MANAGEMENT_KEY
  #   openrouter_inference_key: PLACEHOLDER_REPLACE_WITH_INFERENCE_KEY
  #   moonshot_api_key: PLACEHOLDER_REPLACE_WITH_MOONSHOT_KEY
  #   deepseek_api_key: PLACEHOLDER_REPLACE_WITH_DEEPSEEK_KEY
  #   EOF
  #   nix run nixpkgs#sops -- --encrypt --filename-override secrets/usage-dashboard.yml \
  #     --input-type yaml /tmp/usage-dashboard.yml > secrets/usage-dashboard.yml
  secretsFile = ../../secrets/usage-dashboard.yml;

  # Cle du compte DeepSeek direct : fichier partage avec le provider custom de
  # l'agent hermes (services/hermes), pour n'avoir qu'une copie a faire tourner.
  deepseekSecretFile = ../../secrets/deepseek.yml;
in {
  options.services.usageDashboard = {
    refreshSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        Intervalle de collecte des API. La page, elle, se rafraichit toutes les
        60 s depuis son navigateur : inutile de descendre plus bas cote
        collecte, les sources (analytics OpenRouter) ne sont pas plus fines.
      '';
    };
    windowDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Fenetre d'analyse affichee (jours).";
    };
    subscriptions = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {type = lib.types.str;};
          monthly = lib.mkOption {
            type = lib.types.nullOr lib.types.float;
            default = null;
          };
          note = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
        };
      });
      default = [];
      example = lib.literalExpression ''
        [
          {name = "Claude MAX"; monthly = 200.0; note = "abonnement Anthropic, hors OpenRouter";}
          {name = "ChatGPT Plus"; monthly = 20.0;}
        ]
      '';
      description = ''
        Abonnements payes hors OpenRouter (Claude MAX, ChatGPT...), affiches
        tels quels dans la section « Hors OpenRouter ». Un montant null affiche
        « abonnement » sans chiffre : rien n'est devine ici.
      '';
    };
  };

  config = {
    users.users.usage-dash = {
      isSystemUser = true;
      group = "usage-dash";
      description = "Dashboard d'usage LLM (lecture des API de facturation)";
    };
    users.groups.usage-dash = {};

    sops.secrets = {
      "usage-dashboard/management_key" = {
        sopsFile = secretsFile;
        key = "openrouter_management_key";
        owner = "usage-dash";
        group = "usage-dash";
        mode = "0400";
      };
      "usage-dashboard/inference_key" = {
        sopsFile = secretsFile;
        key = "openrouter_inference_key";
        owner = "usage-dash";
        group = "usage-dash";
        mode = "0400";
      };
      "usage-dashboard/moonshot_key" = {
        sopsFile = secretsFile;
        key = "moonshot_api_key";
        owner = "usage-dash";
        group = "usage-dash";
        mode = "0400";
      };
      # Compte DeepSeek direct : une cle API ne donne QUE le solde (total,
      # offert, recharge). Le detail par cle/jour n'existe que sur la console
      # platform.deepseek.com, derriere un login.
      # La cle vit dans secrets/deepseek.yml (pas dans usage-dashboard.yml) :
      # c'est la meme valeur que celle du provider custom deepseek-direct de
      # l'agent hermes, une seule source a faire tourner.
      "usage-dashboard/deepseek_key" = {
        sopsFile = deepseekSecretFile;
        key = "deepseek_api_key";
        owner = "usage-dash";
        group = "usage-dash";
        mode = "0400";
      };
    };

    systemd.services.usage-dashboard = {
      description = "Dashboard d'usage LLM (OpenRouter, Moonshot)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        User = "usage-dash";
        Group = "usage-dash";
        Environment = [
          "USAGE_DASHBOARD_HOST=0.0.0.0"
          "USAGE_DASHBOARD_PORT=${toString port}"
          "USAGE_DASHBOARD_PAGE=${./index.html}"
          "USAGE_DASHBOARD_STATE=/var/lib/usage-dashboard/last.json"
          "USAGE_DASHBOARD_MANAGEMENT_KEY_FILE=${config.sops.secrets."usage-dashboard/management_key".path}"
          "USAGE_DASHBOARD_INFERENCE_KEY_FILE=${config.sops.secrets."usage-dashboard/inference_key".path}"
          "USAGE_DASHBOARD_MOONSHOT_KEY_FILE=${config.sops.secrets."usage-dashboard/moonshot_key".path}"
          "USAGE_DASHBOARD_DEEPSEEK_KEY_FILE=${config.sops.secrets."usage-dashboard/deepseek_key".path}"
          "USAGE_DASHBOARD_REFRESH=${toString cfg.refreshSeconds}"
          "USAGE_DASHBOARD_WINDOW_DAYS=${toString cfg.windowDays}"
          "USAGE_DASHBOARD_SUBSCRIPTIONS=${builtins.toJSON cfg.subscriptions}"
        ];
        StateDirectory = "usage-dashboard";
        StateDirectoryMode = "0750";
        ExecStart = "${pkgs.python3}/bin/python3 ${./usage_dashboard.py}";
        Restart = "always";
        RestartSec = 5;

        # Durcissement : le service sort en HTTPS et ne sert que du HTTP.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        ReadWritePaths = ["/var/lib/usage-dashboard"];
      };
    };

    # Le port reste ferme au firewall : acces par le tailnet (interface de
    # confiance) ou par le SSO Pangolin via newt, jamais en clair depuis le LAN.
    services.newt.blueprint.proxy-resources.usage-dashboard = {
      name = "usage-dashboard";
      protocol = "http";
      full-domain = domain;
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = port;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = port;
            path = "/healthz";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

    assertions = [
      {
        assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
        message = "usage-dashboard : le port ${toString port} ne doit pas etre ouvert au firewall (acces tailnet + SSO Pangolin uniquement).";
      }
    ];
  };
}
