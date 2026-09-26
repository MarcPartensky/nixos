{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
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
    environmentFiles = [
      config.sops.secrets."hermes_env".path
      config.sops.secrets."hermes_matrix_env".path
    ];
    addToSystemPackages = true;

    # venv nix scellé -> deps mem0 (mem0ai) installées au runtime dans une cible durable
    environment.HERMES_LAZY_INSTALL_TARGET = "/var/lib/hermes/.hermes/lazy-python";

    # --- Matrix : bot @hermes (Element + ponts mautrix) ---
    environment.MATRIX_HOMESERVER = "https://matrix.marcpartensky.com";
    environment.MATRIX_USER_ID = "@hermes:matrix.marcpartensky.com";
    # salles du pont = chiffrées E2EE (encryption.default=true côté mautrix-signal)
    environment.MATRIX_E2EE_MODE = "required";
    # salle de pont = 3+ membres (bot du pont inclus) -> pas classée DM :
    # réponse sans mention, et pas d'auto-thread (les ponts aplatissent les threads)
    environment.MATRIX_REQUIRE_MENTION = "false";
    environment.MATRIX_AUTO_THREAD = "false";
    # @marc + son ghost Signal (mautrix-signal)
    environment.MATRIX_ALLOWED_USERS = "@marc:matrix.marcpartensky.com,@signal_ad927dda-4064-48ff-8652-01a0d71005e4:matrix.marcpartensky.com";

    # psycopg2 buildé par nix (évite le wheel manylinux psycopg2-binary)
    # numpy : les wheels manylinux cassent sur NixOS (libstdc++.so.6 absent) —
    # les deps compilées des lazy-installs doivent venir de nix
    # ATTENTION : les paquets DOIVENT être de l'interpréteur du venv. La famille
    # python est pilotée par pm/lock.json (nix/pythonLock.nix, ici 3.14) ; un
    # paquet d'une autre famille est filtré silencieusement par hasPythonModule
    # -> PYTHONPATH sans le paquet. package.python.pkgs suit le venv.
    extraPythonPackages = with config.services.hermes-agent.package.python.pkgs; [ psycopg2 numpy ];

    # groupes de deps du pyproject résolus par uv DANS le venv scellé (pas de
    # PYTHONPATH) :
    # - "matrix" : mautrix[encryption] + python-olm (libolm embarqué)
    #   -> adaptateur Matrix du gateway (plugins/platforms/matrix)
    # - "edge-tts" : SDK edge-tts (7.2.7, pur python) du provider TTS gratuit
    #   par défaut. Sans lui, l'outil tts échoue avec "No TTS provider
    #   available" (le venv nix ne contient aucun moteur TTS).
    extraDependencyGroups = ["matrix" "edge-tts"];

    # claude-code CLI sur le PATH du service : requis par le plugin officiel
    # claude-subscription-directsdk (provider sur abonnement Claude Pro/Max,
    # login OAuth via `claude`, pas de clé API)
    extraPackages = [
      pkgs.claude-code
      # node/npm : requis par le MCP GitHub (npx -y @modelcontextprotocol/server-github)
      pkgs.nodejs_22
    ];
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

      # --- Modèle par défaut : Claude Sonnet 5 (abonnement Claude Pro/Max) ---
      # Politique marc du 26/09/2026 : sonnet high par défaut, puis les gratuits
      # OpenRouter, DeepSeek Flash en dernier recours. ATTENTION : consomme le
      # quota de l'abonnement à CHAQUE message (plus un simple secours occasionnel) ;
      # quota reset ~6h (cf mémoire hermes). Surveiller l'usure du quota.
      model = {
        provider = "claude-subscription-directsdk-experimental";
        default = "claude-sonnet-5";
      };

      # --- Chaîne de secours si le primaire tombe (rate limit, 5xx, auth) ---
      # essayés dans l'ordre, Bascule au milieu de session sans perdre la conv.
      # 1-2. gratuits OpenRouter : inkling:free (1M ctx, Thinking Machines) puis
      #    nemotron 3 ultra:free (1M ctx, Nvidia). Vérifié le 24/09/2026 : 1000
      #    req/jour autorisées sur les variantes :free de la clé OpenRouter.
      # 3. DeepSeek V4.1 Flash (payant mais bon marché, ~$0.04/$0.49 par M tokens)
      #    en dernier recours si les gratuits sont aussi indisponibles/rate-limited.
      #    base_url explicite : la clé est écrite à chaque activation, donc une
      #    valeur impérative périmée dans config.yaml est écrasée.
      fallback_providers = [
        {
          provider = "openrouter";
          model = "thinkingmachines/inkling:free";
        }
        {
          provider = "openrouter";
          model = "nvidia/nemotron-3-ultra-550b-a55b:free";
        }
        {
          provider = "openrouter";
          model = "deepseek/deepseek-v4.1-flash";
          base_url = "https://openrouter.ai/api/v1";
          context_length = 1048576;
          supports_vision = true;
        }
      ];

      agent = {
        reasoning_effort = "max";
        # Politique marc du 25/09/2026 : le niveau suit le modèle.
        # DeepSeek Flash -> high ; Opus 5 -> max ; Sonnet 5 -> high.
        # Deux clés par famille : forme complète (deepseek/... , modèle par défaut)
        # et forme nue ([1m] des salons, route de secours) ; la résolution est
        # tolérante aux variantes de nommage.
        reasoning_overrides = {
          "deepseek/deepseek-v4.1-flash" = "high";
          "deepseek-v4.1-flash" = "high";
          "claude-opus-5[1m]" = "max";
          "claude-opus-5" = "max";
          "claude-sonnet-5[1m]" = "high";
          "claude-sonnet-5" = "high";
        };
      };

      # --- Coût estimé dans la status bar CLI/TUI ---
      # interface = "tui" : le REPL classique n'écrit AUCUN titre de terminal
      # (aucun module terminal_title dans la version installée), alors que le TUI
      # publie son titre en OSC 0/1/2 : "<etat> <session> · <modele> · <cwd>".
      # C'est ce titre que herdr lit pour l'etat (blocked/working/done) ET pour
      # afficher le modele de chaque pane dans sa sidebar (modules/nixos/herdr).
      # Sans ce reglage, les panes hermes n'exposent pas leur modele a herdr.
      display = {
        show_cost = true;
        interface = "tui";
      };

      # --- Plugin herdr : volontairement desactive ---
      # `herdr integration install hermes` ecrit plugins.enabled =
      # ["herdr-agent-state"] dans config.yaml, et le merge de l'activation
      # conserve les cles non declarees ici : sans cette liste vide, l'entree
      # reste et pointe un plugin absent (fichiers retires).
      # Le plugin herdr sort immediatement si HERDR_ENV != 1, or le lancement
      # habituel (`sudo su -l hermes hermes chat`) efface l'environnement herdr :
      # il ne peut pas fonctionner en l'etat. A installer pour de bon (fichiers
      # declaratifs + lancement qui conserve HERDR_*) si ce besoin revient.
      plugins = {
        enabled = [];
      };

      # --- TTS : Edge TTS (gratuit, sans clé API) ---
      # Voix française par défaut (Hermes répond en français). Le SDK est fourni
      # par extraDependencyGroups = "edge-tts" ci-dessus ; sans ce groupe l'outil
      # tts échoue. Autres voix fr : fr-FR-HenriNeural (masculin),
      # fr-FR-VivienneMultilingualNeural, fr-FR-RemyMultilingualNeural,
      # fr-CA-SylvieNeural. Liste complète : `edge-tts --list-voices`.
      # Lecture automatique des réponses : voice.auto_tts (défaut false ;
      # à la demande via /voice tts en CLI).
      tts = {
        provider = "edge";
        edge = {
          voice = "fr-FR-DeniseNeural";
        };
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

      # --- Modèle par salon Matrix : politique channel_overrides ---
      # La plupart des salons restent sur le défaut (DeepSeek v4.1 via OpenRouter).
      # Les salons ci-dessous tournent sur l'abonnement Claude (DirectSDK) :
      # Opus 5 (O5), ou Sonnet 5 à effort high pour Zoé (S5 high, 1M).
      # Lu par le gateway à son démarrage (un restart est requis après le switch).
      platforms = {
        matrix = {
          channel_overrides = {
            "!zQZcqfoWStODYAuIUE:matrix.marcpartensky.com" = {
              provider = "claude-subscription-directsdk-experimental";
              model = "claude-opus-5[1m]";
            };
            "!zOyDctBWcuFCJKJINI:matrix.marcpartensky.com" = {
              provider = "claude-subscription-directsdk-experimental";
              model = "claude-opus-5[1m]";
            };
            "!sylSYxsYVJRknngRnF:matrix.marcpartensky.com" = {
              provider = "claude-subscription-directsdk-experimental";
              model = "claude-sonnet-5[1m]";
            };
          };
        };
      };
    };
  };

  # --- MCP GitHub : serveur officiel (@modelcontextprotocol/server-github) ---
  # Note : le package est déprécié (2025.4.8) mais toujours fonctionnel.
  # Remplacer le placeholder par le vrai token GitHub (fine-grained PAT).
  services.hermes-agent.mcpServers.github = {
    command = "npx";
    args = [ "-y" "@modelcontextprotocol/server-github" ];
    env = {
      GITHUB_PERSONAL_ACCESS_TOKEN = "ghp_PLACEHOLDER_REPLACE_WITH_REAL_TOKEN";
    };
    timeout = 60;
  };

  # --- node/npm requis pour le serveur GitHub (npx) ---
  # (ajouté dans extraPackages plus haut : l'option n'accepte qu'une définition)

  # --- ollama : embeddings locaux pour mem0 ---
  # nomic-embed-text = 768 dims, supporté par le plugin mem0. CPU suffit.
  services.ollama = {
    enable = true;
    loadModels = ["nomic-embed-text"];
  };

  # claude aussi dispo pour marc et les sessions CLI de hermes
  environment.systemPackages = [pkgs.claude-code];

  sops.secrets."hermes_env" = {};

  # Token Matrix du bot (@hermes) — clé "hermes_matrix_env" du fichier sops,
  # valeur = contenu dotenv (MATRIX_ACCESS_TOKEN=...) fusionné dans .env
  sops.secrets."hermes_matrix_env" = {
    sopsFile = ../../secrets/hermes-matrix.yml;
  };

  # --- Accès SSH direct de hermes (tower) vers les autres hôtes qui importent
  # ce module (laptop, anywhere) : ouvre un shell (et-session + zellij) pour
  # agir/builder directement sur la machine, sans copier-coller par marc.
  # Même clé que celle déjà posée pour root sur anywhere (25/09/2026).
  users.users.hermes.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
  ];

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

  # --- La règle sudo ci-dessus était INOPÉRANTE depuis les unités hermes ---
  # Le module hermes-agent pose NoNewPrivileges=true dans le serviceConfig
  # commun au gateway (hermes-agent.service) et au backend (hermes-backend.
  # service). Sous ce flag le noyau IGNORE le bit setuid : sudo refuse net
  # (« the "no new privileges" flag is set »), su échoue au setuid(), et le
  # flag s'hérite par tous les enfants. Conséquence : une session ouverte
  # depuis Matrix ou depuis le terminal web ne pouvait PAS lancer le
  # nixos-rebuild que la règle NOPASSWD lui accorde pourtant.
  #
  # On le désactive donc sur les deux unités. Ça ne donne pas de shell root :
  # sudo reste borné à la liste de commandes ci-dessus.
  systemd.services.hermes-agent.serviceConfig.NoNewPrivileges = lib.mkForce false;
  systemd.services.hermes-backend.serviceConfig.NoNewPrivileges = lib.mkForce false;

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
