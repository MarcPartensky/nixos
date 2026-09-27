{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  # Option : le token Matrix du bot @hermes (clé hermes_matrix_env de
  # secrets/hermes-matrix.yml). Les destinataires de ce fichier sops ne
  # contiennent PAS les clés age de anywhere/laptop : ne l'activer que sur les
  # hôtes capables de le déchiffrer (tower), sinon l'activation (setupSecrets)
  # échoue et hermes-agent démarre sans son fichier d'env.
  options.services.hermes.enableMatrixToken = lib.mkEnableOption ''
    le token Matrix du bot @hermes (secrets/hermes-matrix.yml, destinataires = tower uniquement)
  '';

  config = {
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
      environmentFiles =
        [ config.sops.secrets."hermes_env".path ]
        ++ lib.optional config.services.hermes.enableMatrixToken config.sops.secrets."hermes_matrix_env".path;
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
      # numpy N'EST PLUS LISTÉ ICI : depuis l'ajout de "stt-whisper" (onnxruntime ->
      # numpy 2.4.3) le venv scellé le fournit lui-même, et le build du paquet hermes
      # ÉCHOUE si un paquet de extraPythonPackages doublonne le venv ("plugin package
      # \"numpy\" collides with a package in hermes sealed venv"). Le numpy du venv
      # (buildé par nix) sert aussi aux lazy-installs runtime : wheel manylinux cassée
      # sur NixOS (libstdc++.so.6 absent), d'où l'ancienne présence ici.
      # ATTENTION : les paquets DOIVENT être de l'interpréteur du venv. La famille
      # python est pilotée par pm/lock.json (nix/pythonLock.nix, ici 3.14) ; un
      # paquet d'une autre famille est filtré silencieusement par hasPythonModule
      # -> PYTHONPATH sans le paquet. package.python.pkgs suit le venv.
      extraPythonPackages = with config.services.hermes-agent.package.python.pkgs; [ psycopg2 ];

      # groupes de deps du pyproject résolus par uv DANS le venv scellé (pas de
      # PYTHONPATH) :
      # - "matrix" : mautrix[encryption] + python-olm (libolm embarqué)
      #   -> adaptateur Matrix du gateway (plugins/platforms/matrix)
      # - "edge-tts" : SDK edge-tts (7.2.7, pur python) du provider TTS gratuit
      #   par défaut. Sans lui, l'outil tts échoue avec "No TTS provider
      #   available" (le venv nix ne contient aucun moteur TTS).
      # - "stt-whisper" : faster-whisper (transcription locale, gratuite, CPU) pour
      #   les vocaux entrants. Sans lui le gateway répond "voice message could not
      #   be transcribed automatically" et le cas d'usage "je parle dans mes
      #   écouteurs depuis Element" ne marche pas.
      extraDependencyGroups = ["matrix" "edge-tts" "stt-whisper"];

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

        # --- Modèle par défaut : Nemotron 3 Ultra gratuit (OpenRouter) ---
        # Politique marc du 27/09/2026 : nemotron-3-ultra:free high par défaut,
        # puis inkling:free, DeepSeek Flash en dernier recours.
        model = {
          provider = "openrouter";
          default = "nvidia/nemotron-3-ultra-550b-a55b:free";
        };

        # --- Chaîne de secours si le primaire tombe (rate limit, 5xx, auth) ---
        # essayés dans l'ordre, Bascule au milieu de session sans perdre la conv.
        # 1. inkling:free (1M ctx, Thinking Machines) gratuit OpenRouter.
        # 2. DeepSeek V4.1 Flash (payant mais bon marché, ~$0.04/$0.49 par M tokens)
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
            "nvidia/nemotron-3-ultra-550b-a55b:free" = "high";
            "nemotron-3-ultra" = "high";
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
          # Thème Catppuccin Mocha (dark) + accent Lavender, demandé par marc
          # le 26/09/2026. Fichier de palette : skins/catppuccin-dark-lavender.yaml
          # sous /var/lib/hermes/.hermes/skins/ (pas géré par nix, écrit au runtime).
          skin = "catppuccin-dark-lavender";
        };

        # --- Plugin herdr : integre hermes a herdr, declarativement ---
        # `extraPlugins` symlinke le paquet dans /var/lib/hermes/.hermes/plugins/
        # (sous le nom nix-managed-<nom>) ; le code du plugin est vendorise dans
        # services/hermes/plugins/herdr-agent-state (recopie de ce que produit
        # `herdr integration install hermes`), donc plus d'install imperative.
        # Ce plugin rapporte l'ID DE SESSION a herdr (herdr pane
        # report-agent-session), ce qui permet a herdr de relancer le pane dans sa
        # conversation (`hermes --resume <id>`, option [session]
        # resume_agents_on_restore).
        # LIMITE : le plugin sort immediatement si HERDR_ENV != 1 ou sans
        # HERDR_PANE_ID, et il parle au socket herdr de MARC
        # (~/.config/herdr/herdr.sock) : il ne peut donc fonctionner que si hermes
        # tourne dans le pane avec l'env herdr et sous le meme utilisateur que le
        # serveur herdr. Le lancement habituel (`sudo su -l hermes hermes chat`)
        # efface cet env -> plugin inerte mais sans effet de bord.
        plugins = {
          enabled = [ "herdr-agent-state" ];
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

        # --- STT : faster-whisper local (gratuit, CPU, sans clé API) ---
        # Transcrit automatiquement les vocaux entrants (Matrix/Element, etc.) :
        # le gateway transcrit tout message vocal quand stt.enabled est vrai.
        # Le moteur vient du groupe "stt-whisper" ci-dessus.
        # language = "" est IMPORTANT : la valeur par défaut est "en", qui force
        # Whisper à décoder du français comme de l'anglais. Vide = détection
        # automatique (mesuré : fr détecté à p=0.99 sur un vocal court).
        # Modèle "base" (140 Mo, ~5 s pour 3 s d'audio, CPU) ; "small" ou "medium"
        # si la précision ne suffit pas avec un micro d'écouteurs en environnement
        # bruyant. provider non déclaré = échelle auto (local d'abord).
        stt = {
          enabled = true;
          language = "";
          local = {
            model = "base";
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

      # --- Plugin herdr : integre hermes a herdr, declarativement ---
      # Option de SERVICE (pas dans settings : un extraPlugins mis dans settings
      # finit juste comme cle inerte de config.yaml, et aucun symlink n'est cree).
      # `extraPlugins` symlinke le paquet dans /var/lib/hermes/.hermes/plugins/
      # sous le nom nix-managed-<nom> ; le code du plugin est vendorise dans
      # services/hermes/plugins/herdr-agent-state (recopie de ce que produit
      # `herdr integration install hermes`), donc plus d'install imperative.
      # Ce plugin rapporte l'ID DE SESSION a herdr (herdr pane
      # report-agent-session), ce qui permet a herdr de relancer le pane dans sa
      # conversation (`hermes --resume <id>`, option [session]
      # resume_agents_on_restore).
      # LIMITE : le plugin sort immediatement si HERDR_ENV != 1 ou sans
      # HERDR_PANE_ID, et il parle au socket herdr de MARC
      # (~/.config/herdr/herdr.sock, 0600, dossier 0700) : il ne peut donc
      # fonctionner que si hermes tourne dans le pane avec l'env herdr ET sous
      # l'utilisateur marc. Le lancement habituel (`sudo su -l hermes hermes
      # chat`) efface cet env -> plugin inerte mais sans effet de bord.
      extraPlugins = [
        (pkgs.runCommandLocal "herdr-agent-state" {} ''
          mkdir -p $out
          cp ${./plugins/herdr-agent-state/plugin.yaml} $out/plugin.yaml
          cp ${./plugins/herdr-agent-state/__init__.py} $out/__init__.py
        '')
      ];
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
    # python3 SYSTEME (pas celui du venv scelle) : le probe de demarrage SSH de
    # Hermes Desktop execute `python3 -c ...` sur la machine distante pour lire
    # ~/.hermes-update-in-progress. Sans python3 dans le PATH ssh, TOUTE connexion
    # Desktop en SSH echoue avec "Could not prove that the remote Hermes install
    # is clear for SSH startup." (verifie le 27/09/2026)
    environment.systemPackages = [pkgs.claude-code pkgs.python3];

    sops.secrets."hermes_env" = {};

    # Token Matrix du bot (@hermes) — clé "hermes_matrix_env" du fichier sops,
    # valeur = contenu dotenv (MATRIX_ACCESS_TOKEN=...) fusionné dans .env.
    # Déclaré uniquement là où l'option est active : les destinataires du fichier
    # n'incluent pas anywhere/laptop, y déclarer le secret ferait échouer
    # l'activation (setupSecrets « 0 successful groups required »).
    sops.secrets."hermes_matrix_env" = lib.mkIf config.services.hermes.enableMatrixToken {
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
  };
}
