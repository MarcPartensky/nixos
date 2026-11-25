# services/usage-dashboard: LLM usage dashboard, all providers.
#
# Chain: Pangolin (usage.marcpartensky.com, WITHOUT SSO) -> newt (tower site)
#          -> 127.0.0.1:9141 (this service).
# The public domain is deliberately open (no Pangolin SSO, cf. below):
# publish only aggregates there, never a secret.
# From the tailnet, the direct URL is http://100.64.0.3:9141 (no SSO:
# tailscale0 is already a trusted interface, cf. services/tailscale).
#
# Two units, two roles:
#   - usage-dashboard-agent-usage (5 min timer, user hermes) reads Hermes's
#     state.db and writes a JSON aggregate into
#     /var/lib/usage-dashboard-agent/. It is the only source that covers ALL
#     providers and gives the detail per model / surface / day.
#   - usage-dashboard (user usage-dash) joins this aggregate to the billing
#     API balances and serves the page + /api/data.
# The separation exists because state.db belongs to hermes and the web
# service has no reason to be able to read it.
#
# The web service only READS: OpenRouter balance and usage, analytics
# (cross-check of the estimated cost), Moonshot and DeepSeek balance, USD->EUR
# rate. It writes only its startup cache and the balance history
# (StateDirectory), which serves to measure the consumption in real money.
#
# Two OpenRouter keys, two roles:
#   - openrouter_management_key: ONLY key that opens /api/v1/analytics, hence
#     the only source of the per-model detail. It cannot do inference
#     (read-only, free). To create at
#     https://openrouter.ai/settings/management-keys then write into
#     secrets/usage-dashboard.yml (see the command in a comment below).
#   - openrouter_inference_key: the key that actually serves hermes, for
#     the real-time usage of the key (/api/v1/key: day / week / month).
# As long as one of the two is a placeholder, the page still deploys and
# shows what it can, with the state of each source in its footer.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.usageDashboard;

  port = 9141;
  domain = "usage.marcpartensky.com";

  # Secrets: two OpenRouter keys + the Moonshot key (kimi direct provider).
  # Creation of the file (tower's age encrypts, no private key required):
  #   cat > /tmp/usage-dashboard.yml <<'EOF'
  #   openrouter_management_key: PLACEHOLDER_REPLACE_WITH_MANAGEMENT_KEY
  #   openrouter_inference_key: PLACEHOLDER_REPLACE_WITH_INFERENCE_KEY
  #   moonshot_api_key: PLACEHOLDER_REPLACE_WITH_MOONSHOT_KEY
  #   deepseek_api_key: PLACEHOLDER_REPLACE_WITH_DEEPSEEK_KEY
  #   EOF
  #   nix run nixpkgs#sops -- --encrypt --filename-override secrets/usage-dashboard.yml \
  #     --input-type yaml /tmp/usage-dashboard.yml > secrets/usage-dashboard.yml
  secretsFile = ../../secrets/usage-dashboard.yml;

  # Key of the direct DeepSeek account: file shared with the custom provider of
  # the hermes agent (services/hermes), to have only one copy to rotate.
  deepseekSecretFile = ../../secrets/deepseek.yml;
  # Same file as the agent's "hermes_gemini_env" secret (dotenv content
  # "GOOGLE_API_KEY=..."): the dashboard renders a copy of it readable by
  # usage-dash, without duplicating the key in a second encrypted file.
  geminiSecretFile = ../../secrets/hermes-gemini.yml;
in {
  options.services.usageDashboard = {
    refreshSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        Collection interval of the APIs. The page itself refreshes every
        60 s from its browser: no point going lower on the
        collection side, the sources (OpenRouter analytics) are not finer.
      '';
    };
    windowDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = ''
        Largest window analyzed (days): the page offers 24 h, 7, 30 and
        this value. The daily series cover the whole window, the
        browser slices it, so a single collection is enough for all choices.
      '';
    };
    hermesHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes";
      description = ''
        Root of the Hermes installation read by the usage collector
        (state.db of the default profile and of each profile under profiles/).
      '';
    };
    hermesUser = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "User owning state.db; the collector runs under its identity.";
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
          {name = "Claude MAX"; monthly = 200.0; note = "Anthropic subscription, outside OpenRouter";}
          {name = "ChatGPT Plus"; monthly = 20.0;}
        ]
      '';
      description = ''
        Subscriptions paid outside OpenRouter (Claude MAX, ChatGPT...), shown
        as is in the "Outside OpenRouter" section. A null amount shows
        "subscription" without a number: nothing is guessed here.
      '';
    };
  };

  config = {
    users.users.usage-dash = {
      isSystemUser = true;
      group = "usage-dash";
      description = "LLM usage dashboard (reads the billing APIs)";
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
      # Direct DeepSeek account: an API key gives ONLY the balance (total,
      # granted, topped up). The detail per key/day exists only on the console
      # platform.deepseek.com, behind a login.
      # The key lives in secrets/deepseek.yml (not in usage-dashboard.yml):
      # it is the same value as the deepseek-direct custom provider of
      # the hermes agent, a single source to rotate.
      "usage-dashboard/deepseek_key" = {
        sopsFile = deepseekSecretFile;
        key = "deepseek_api_key";
        owner = "usage-dash";
        group = "usage-dash";
        mode = "0400";
      };
      # Google AI Studio (Hermes's built-in gemini provider): no balance
      # endpoint, so the dashboard puts a health probe there instead. Same
      # value as the agent's GOOGLE_API_KEY, rendered a second time here so
      # that the usage-dash service (and it alone) can read it.
      "usage-dashboard/gemini_key" = {
        sopsFile = geminiSecretFile;
        key = "hermes_gemini_env";
        owner = "usage-dash";
        group = "usage-dash";
        mode = "0400";
      };
    };

    systemd.services.usage-dashboard = {
      description = "LLM usage dashboard (OpenRouter, Moonshot)";
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
          "USAGE_DASHBOARD_HISTORY=/var/lib/usage-dashboard/balances.json"
          "USAGE_DASHBOARD_AGENT_FILE=/var/lib/usage-dashboard-agent/agent-usage.json"
          "USAGE_DASHBOARD_CLAUDE_PLAN_FILE=/var/lib/usage-dashboard-agent/claude-plan.json"
          "USAGE_DASHBOARD_MANAGEMENT_KEY_FILE=${config.sops.secrets."usage-dashboard/management_key".path}"
          "USAGE_DASHBOARD_INFERENCE_KEY_FILE=${config.sops.secrets."usage-dashboard/inference_key".path}"
          "USAGE_DASHBOARD_MOONSHOT_KEY_FILE=${config.sops.secrets."usage-dashboard/moonshot_key".path}"
          "USAGE_DASHBOARD_DEEPSEEK_KEY_FILE=${config.sops.secrets."usage-dashboard/deepseek_key".path}"
          "USAGE_DASHBOARD_GEMINI_KEY_FILE=${config.sops.secrets."usage-dashboard/gemini_key".path}"
          "USAGE_DASHBOARD_REFRESH=${toString cfg.refreshSeconds}"
          "USAGE_DASHBOARD_WINDOW_DAYS=${toString cfg.windowDays}"
          "USAGE_DASHBOARD_SUBSCRIPTIONS=${builtins.toJSON cfg.subscriptions}"
        ];
        StateDirectory = "usage-dashboard";
        StateDirectoryMode = "0750";
        # The whole service folder is copied into the store: the scripts
        # import providers.py, which must therefore be next to them. An
        # isolated file copied into the store would not have this neighborhood.
        ExecStart = "${pkgs.python3}/bin/python3 ${./.}/usage_dashboard.py";
        Restart = "always";
        RestartSec = 5;

        # Hardening: the service goes out over HTTPS and only serves HTTP.
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

    # Usage collector: reads Hermes's databases (owner hermes) and
    # publishes a JSON aggregate. Launched by timer, not at the startup of the
    # web service: the page shows the freshness of this aggregate and stays usable
    # even if the collector is late.
    systemd.services.usage-dashboard-agent-usage = {
      description = "Aggregates the LLM usage recorded by Hermes (state.db)";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.hermesUser;
        Group = cfg.hermesUser;
        StateDirectory = "usage-dashboard-agent";
        # Readable by the web service (another user): these are cost
        # aggregates, not sensitive data.
        StateDirectoryMode = "0755";
        ExecStart = "${pkgs.python3}/bin/python3 ${./.}/agent_usage.py";
        Environment = [
          "AGENT_USAGE_HOME=${cfg.hermesHome}/.hermes"
          "AGENT_USAGE_OUT=/var/lib/usage-dashboard-agent/agent-usage.json"
          "AGENT_USAGE_WINDOW_DAYS=${toString cfg.windowDays}"
        ];
        TimeoutStartSec = "120";

        # Read-only on state.db: same hardening as the web service
        # (ProtectSystem=strict makes / read-only, the StateDirectory is
        # the only writable zone).
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_UNIX"];
      };
    };

    systemd.timers.usage-dashboard-agent-usage = {
      description = "Refreshes the Hermes usage aggregate";
      wantedBy = ["timers.target"];
      timerConfig = {
        Unit = "usage-dashboard-agent-usage.service";
        OnBootSec = "90s";
        OnUnitActiveSec = "300s";
        AccuracySec = "30s";
      };
    };

    # Limits of the Claude plan (5 h session, week), the same numbers as
    # /usage in Claude Code: read via Claude Code's OAuth token (hermes),
    # never refreshed here (a refresh would rotate the refresh token and
    # disconnect Claude Code).
    systemd.services.usage-dashboard-claude-plan = {
      description = "Reads the Claude plan limits (oauth/usage)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.hermesUser;
        Group = cfg.hermesUser;
        StateDirectory = "usage-dashboard-agent";
        StateDirectoryMode = "0755";
        ExecStart = "${pkgs.python3}/bin/python3 ${./.}/claude_plan.py";
        Environment = [
          "CLAUDE_PLAN_CREDENTIALS=${cfg.hermesHome}/.claude/.credentials.json"
          "CLAUDE_PLAN_OUT=/var/lib/usage-dashboard-agent/claude-plan.json"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ];
        TimeoutStartSec = "60";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
      };
    };

    systemd.timers.usage-dashboard-claude-plan = {
      description = "Refreshes the Claude plan limits";
      wantedBy = ["timers.target"];
      timerConfig = {
        Unit = "usage-dashboard-claude-plan.service";
        OnBootSec = "60s";
        OnUnitActiveSec = "180s";
        AccuracySec = "20s";
      };
    };

    # The port stays closed on the firewall: access via the tailnet (trusted
    # interface) or via Pangolin through newt, never in clear from the LAN.
    # SSO DISABLED (marc's request, 18/11/2026): the dashboard must open
    # without login, including from a browser without a Pangolin session. The page
    # is therefore public on the Internet: it shows only balances and
    # aggregate costs, no key. To close it again: set sso-enabled back to true
    # (the POST {sso:true} on resource 69 does the same thing hot).
    services.newt.blueprint.proxy-resources.usage-dashboard = {
      name = "usage-dashboard";
      protocol = "http";
      full-domain = domain;
      auth.sso-enabled = false;
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
        message = "usage-dashboard: port ${toString port} must not be open on the firewall (tailnet access + Pangolin SSO only).";
      }
    ];
  };
}
