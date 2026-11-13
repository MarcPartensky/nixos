{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # claude-code épinglé plus récent que nixpkgs 26.05 (2.1.223).
  # L'API refuse les modèles Opus 5.5 en dessous de 2.1.280 :
  #   "API Error: 400 Claude Code 2.1.223 does not support this model;
  #    version 2.1.280 or newer is required."
  # Le paquet nixpkgs prend son manifeste (version + checksums par plateforme)
  # en argument : on lui passe celui publié par Anthropic pour le canal stable
  # (https://downloads.claude.ai/claude-code-releases/2.1.280/manifest.json),
  # copié tel quel dans ./claude-code-manifest.json. Mise à jour = recopier le
  # manifeste d'une version plus récente, rien d'autre.
  claudeCode = pkgs.claude-code.override {
    manifest = lib.importJSON ./claude-code-manifest.json;
  };

  # MCP Pangolin : plus de paquet ici. Le serveur est monte par
  # modules/nixos/mcp-host directement depuis ./pangolin-mcp.py (entree
  # `pangolin` de profiles/tower/configuration.nix), donc le binaire
  # writePython3Bin ne servait plus a rien et n'etait plus reference nulle
  # part : il ne faisait qu'evaluer un paquet python a chaque eval de l'hote.
in {
  # Option : le token Matrix du bot @hermes (clé hermes_matrix_env de
  # secrets/hermes-matrix.yml). Les destinataires de ce fichier sops ne
  # contiennent PAS les clés age de anywhere/laptop : ne l'activer que sur les
  # hôtes capables de le déchiffrer (tower), sinon l'activation (setupSecrets)
  # échoue et hermes-agent démarre sans son fichier d'env.
  options.services.hermes.enableMatrixToken = lib.mkEnableOption ''
    le token Matrix du bot @hermes (secrets/hermes-matrix.yml, destinataires = tower uniquement)
  '';

  # Option : le token du bot Discord dédié de Hermes (voix + texte natifs, profil
  # `discord-bridge`). Même contrainte que enableMatrixToken : les destinataires
  # de secrets/hermes-discord.yml n'incluent pas anywhere/laptop, donc ne
  # l'activer que sur tower, sinon l'activation (setupSecrets) échoue et
  # hermes-agent démarre sans son fichier d'env.
  options.services.hermes.enableDiscordToken = lib.mkEnableOption ''
    le token Discord du bot Hermes (secrets/hermes-discord.yml, destinataires = tower uniquement)
  '';

  # Option : lancer le gateway hermes-agent (chat) sur cet hôte. Défaut actif
  # partout où ce module est importé. Le couper (ex. VPS racknerd, où le chat
  # est inerte : pas de token Matrix/Discord, modèle DirectSDK sans login
  # claude) retire le service, ollama, claude-code (unfree) et les MCP, mais
  # GARDE l'utilisateur hermes + clé SSH + sudo nixos-rebuild (accès remote).
  options.services.hermes.enableAgent = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Lancer le gateway hermes-agent (chat) sur cet hôte.";
  };

  config = lib.mkMerge [
    {
    # --- utilisateur hermes (accès SSH remote + sudo nixos-rebuild) ---
    # Défini ici pour TOUS les hôtes, même quand le gateway est coupé
    # (enableAgent = false) : c'est via cet utilisateur que hermes@tower
    # déploie et diagnostique les hôtes distants. Le module hermes-agent ne
    # doit pas le recréer (createUser = false).
    users.groups.hermes = {};
    users.users.hermes = {
      isSystemUser = true;
      group = "hermes";
      home = "/var/lib/hermes";
      createHome = true;
      shell = pkgs.bashInteractive;
      # Plage subuid/subgid pour podman rootless (agents : conteneurs d'outils
      # jetables). Sans elle, `podman pull` echoue a l'unpack sur
      # "potentially insufficient UIDs or GIDs available in user namespace".
      # 200000 pour ne pas chevaucher la plage de marc (100000:65536).
      subUidRanges = [{ startUid = 200000; count = 65536; }];
      subGidRanges = [{ startGid = 200000; count = 65536; }];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
      ];
    };
    services.hermes-agent.createUser = false;

    # python3 SYSTEME (pas celui du venv scelle) : le probe de demarrage SSH de
    # Hermes Desktop execute `python3 -c ...` sur la machine distante pour lire
    # ~/.hermes-update-in-progress. Sans python3 dans le PATH ssh, TOUTE connexion
    # Desktop en SSH echoue avec "Could not prove that the remote Hermes install
    # is clear for SSH startup." (verifie le 27/09/2026)
    # claude-code (unfree) n'est ajouté QUE si le gateway tourne sur cet hôte :
    # il ne sert qu'au provider claude-subscription-directsdk (Matrix).
    environment.systemPackages = [pkgs.python3] ++ lib.optionals config.services.hermes.enableAgent [claudeCode];

    # --- Accès SSH direct de hermes (tower) vers les autres hôtes qui importent
    # ce module (laptop, anywhere) : ouvre un shell (et-session + zellij) pour
    # agir/builder directement sur la machine, sans copier-coller par marc.
    # Même clé que celle déjà posée pour root sur anywhere (25/09/2026).
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
    }

    # --- gateway hermes-agent (chat) : actif par défaut, coupable par hôte ---
    (lib.mkIf config.services.hermes.enableAgent {
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
        ++ lib.optional config.services.hermes.enableMatrixToken config.sops.secrets."hermes_matrix_env".path
        ++ lib.optional config.services.hermes.enableDiscordToken config.sops.secrets."hermes_discord_env".path
        # API_SERVER_KEY : la valeur chiffrée est la CLÉ NUE (64 hex), pas un
        # dotenv « API_SERVER_KEY=... ». Le module ne fait que CONCATÉNER les
        # environmentFiles dans $HERMES_HOME/.env, donc la clé arrivait seule sur
        # une ligne sans nom de variable : API_SERVER_KEY restait vide,
        # l'api_server refuse de démarrer sans clé utilisable (min 16 car.), et
        # le pont Discord (services/discord-bot -> 127.0.0.1:8642) n'avait plus
        # de listener. Un template sops-nix préfixe la clé.
        ++ [ config.sops.templates."hermes-api-server.env".path ]
        # DEEPSEEK_API_KEY (compte direct), consommée par le provider custom
        # provider deepseek : sans ce fichier le provider existe mais l'appel part
        # sans jeton et rend 401.
        ++ [ config.sops.secrets."hermes_deepseek_env".path ];
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

      # --- Discord : NATIF DESACTIVE (cf. profiles/tower : enableDiscordToken) ---
      # Historiquement : bot dedie (voix + texte) sur le profil `discord-bridge`.
      # Aujourd'hui Discord est servi par services/discord-bot (bot de marc) qui
      # appelle l'API server du profil default sous /p/discord-bridge/. La
      # plateforme native reste donc desactivee : son token sops est un
      # placeholder et discord.py n'est pas dans le venv scelle, ce qui la
      # faisait apparaitre "down" en permanence. Allowlist conservee pour le jour
      # ou elle sera reactivee (@marc uniquement, id Discord).
      environment.DISCORD_ALLOWED_USERS = "478552571510915072";

      # --- Opus (voix Discord) : voir le bloc "Opus" plus bas, au niveau `config`
      # (l'env du process se pose sur l'unité systemd, pas via `environment`, qui
      # n'écrit que $HERMES_HOME/.env) ---

      # --- API Server (OpenAI-compatible) : UN SEUL listener pour l'hôte ---
      # La topologie de Hermes est "un gateway par hôte qui sert tous les profils"
      # (multiplex). Un profil secondaire qui demande son API server n'obtient PAS
      # son propre port : le listener du profil default le sert sous
      # /p/<profil>/... (log gateway : "api_server is served by the default
      # profile's listener at /p/<profil>/ — not starting a second listener").
      # C'est ce que consomme le pont Discord : services/discord-bot appelle
      # http://127.0.0.1:8642/p/discord-bridge/v1/chat/completions.
      # Bind loopback uniquement, clé obligatoire (sops), jamais ouvert au
      # firewall, jamais routé par Pangolin.
      environment.API_SERVER_ENABLED = "true";
      environment.API_SERVER_PORT = "8642";

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
      # - "anthropic" : paquet du provider natif `anthropic`, celui des lignes du
      #   sélecteur de modèle SANS suffixe [1m] (claude-opus-5-5, claude-opus-5,
      #   claude-sonnet-5). Sans lui, une session ouverte sur une de ces lignes
      #   meurt en agent_init_failed ("The 'anthropic' package is required for the
      #   Anthropic provider"). Les lignes AVEC [1m] passent par le provider
      #   claude-subscription-directsdk (CLI `claude`) et n'en ont pas besoin.
      #   Auth de ce provider natif : pas de clé API, agent/anthropic_credentials.py
      #   prend l'OAuth de l'abonnement dans ~/.claude/.credentials.json (refresh et
      #   réécriture gérés par Hermes) ou un grant Hermes
      #   (hermes auth add anthropic --type oauth).
      extraDependencyGroups = ["matrix" "edge-tts" "stt-whisper" "anthropic"];

      # claude-code CLI sur le PATH du service : requis par le plugin officiel
      # claude-subscription-directsdk (provider sur abonnement Claude Pro/Max,
      # login OAuth via `claude`, pas de clé API)
      extraPackages = [
        claudeCode
        # node/npm : requis par le MCP GitHub (npx -y @modelcontextprotocol/server-github)
        pkgs.nodejs_22
        # binutils : donne `ld` et `objdump` sur le PATH, dont dépend le repli de
        # ctypes.util.find_library("opus") pour libopus (voix Discord). Voir le
        # bloc "Opus" plus bas.
        pkgs.binutils
        # ffmpeg : requis par la voix Discord des DEUX côtés (conversion du TTS en
        # PCM 48 kHz pour la sortie, et décodage côté réception). Sans lui dans le
        # PATH du service, `hermes doctor` signale "install out of sync" et la
        # lecture en vocal échoue.
        pkgs.ffmpeg
      ];
      # settings.model = {
      #   base_url = "https://api.anthropic.com/v1";
      #   default = "anthropic/claude-sonnet-4";
      # };
      settings = {
        # --- Limites de la mémoire persistante ---
        # La mémoire (MEMORY.md, injectée à CHAQUE tour) est plafonnée par défaut
        # à 2200 chars (~800 tokens) et le profil utilisateur (USER.md) à 1375.
        # Valeurs relevées dans le code (tools/memory_tool.py) : les clés lues
        # sont memory_char_limit / user_char_limit dans la section `memory`.
        # Le savoir procédural reste dans les skills (chargés à la demande) ;
        # ces limites ne servent qu'aux faits valables dans toute session.
        memory = {
          memory_char_limit = 6000; # ~2200 tokens, contre 2200 chars par défaut
          user_char_limit = 3000; # ~1100 tokens, contre 1375 par défaut
        };

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

          # --- Provider custom : llama.cpp + llama-swap du portable ---
          # Le portable (RTX 3060 6 Go) sert plusieurs GGUF sur UN seul port
          # compatible OpenAI, joint par le tailnet (100.64.0.4:8080). Serveur
          # local sans cle : pas de key_env, Hermes substitue « no-key-required ».
          # qwen3.5-4b est le seul modele confortable dans Hermes (64k, 20-40
          # tok/s mesures, appels d'outils corrects) ; qwen3.5-2b est minuscule
          # et rapide ; ornith-9b plafonne a 16k et ~5 tok/s (interface web
          # de llama-swap seulement). Cette entree doit vivre ICI : une entree
          # ajoutee a chaud dans config.yaml est ecrasee a l'activation (le
          # merge Nix remplace les listes, il ne les fusionne pas).
          {
            name = "laptop-llama";
            base_url = "http://100.64.0.4:8080/v1";
            api_mode = "chat_completions";
            model = "qwen3.5-4b";
            models = {
              "qwen3.5-4b".context_length = 65536;
              "qwen3.5-2b".context_length = 65536;
              "ornith-9b".context_length = 16384;
            };
          }

          # --- Provider custom : Qwen3.5 4B abliterated sur le portable ---
          # Second endpoint du portable, distinct de llama-swap (100.64.0.4:8080,
          # service SYSTEME `llm-server` en Vulkan) : celui-ci est notre propre
          # llama-server compile en CUDA sm_86, 128k de contexte, KV q4_0.
          # Verifie : prompt de 36 640 tokens avec retrieval exact, pp ~560-680
          # tok/s, 12-27 tok/s en generation, 4.8-5.1 Go de VRAM sur 6.
          # Mesure Hermes reelle : 49 058 tokens d'entree pour un one-shot, donc
          # 8k etait inutilisable et 32k juste ; 128k laisse la marge.
          # Unite cote portable : ~/.config/systemd/user/llama-abl.service.
          {
            name = "laptop-abl";
            base_url = "http://100.64.0.4:8083/v1";
            api_mode = "chat_completions";
            model = "qwen3.5-4b-abl";
            models = {
              "qwen3.5-4b-abl".context_length = 131072;
            };
          }

          # (DeepSeek direct : PAS de provider custom ici, le provider intégré
          # `deepseek` couvre le cas. Il porte le ProviderProfile upstream qui
          # émet `extra_body.thinking` explicitement et mappe l'effort sur
          # `reasoning_effort` : sans ça l'API V4 laisse thinking ON par défaut
          # et exige de renvoyer `reasoning_content` au tour suivant (HTTP 400
          # après le premier appel d'outil). Un provider custom ne reçoit pas ce
          # profil, il ne servait qu'à déclarer les métadonnées 1 M / vision.)
        ];

        # --- Modèle par défaut : DeepSeek v4.1 Flash, servi EN DIRECT ---
        # Politique marc du 11/11/2026 : le compte DeepSeek direct remplace
        # OpenRouter pour le modele par defaut (solde recharge suivi sur
        # usage.marcpartensky.com, hors heures pleines deux fois moins cher).
        # Provider = le slug INTÉGRÉ `deepseek` (pas un custom) : une seule
        # entrée DeepSeek dans le picker, et le ProviderProfile upstream gère
        # le contrat thinking de l'API V4. Le slug custom `deepseek-direct`
        # faisait doublon avec la même paire de modèles.
        # La chaine de secours juste en dessous reste OpenRouter puis le
        # Nemotron gratuit : un solde DeepSeek a zero ne coupe pas l'agent.
        model = {
          provider = "deepseek";
          default = "deepseek-flash";
          # base_url declaree EXPLICITEMENT : le fichier en place gardait
          # https://openrouter.ai/api/v1 du defaut precedent, et un base_url
          # perime avec un nom de modele DeepSeek ferait un 400 silencieux
          # (bascule sur la chaine de secours sans que ca se voie).
          base_url = "https://api.deepseek.com/v1";
        };

        # --- Chaîne de secours : DeepSeek en premier, Nemotron en secours ---
        fallback_providers = [
          {
            provider = "openrouter";
            model = "deepseek/deepseek-v4.1-flash";
            base_url = "https://openrouter.ai/api/v1";
            context_length = 1048576;
            supports_vision = true;
          }
          {
            provider = "openrouter";
            model = "nvidia/nemotron-3-ultra-550b-a55b:free";
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
            # Memes niveaux pour les noms servis par l'API DeepSeek directe
            # (provider intégré `deepseek`). V4-Pro est le gros modele :
            # max, comme Opus 5.
            "deepseek-flash" = "high";
            "deepseek-v4-pro" = "max";
            "nvidia/nemotron-3-ultra-550b-a55b:free" = "max";
            "nemotron-3-ultra" = "max";
            "claude-opus-5-5[1m]" = "max";
            "claude-opus-5-5" = "max";
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

        # --- Approbations de commandes : plus aucune validation humaine ---
        # Politique marc du 13/10/2026 : le shell ne demande plus rien avant
        # d'executer une commande. "off" est le troisieme bypass du gate
        # (tools/approval.py, is_approval_bypass_active_for_session : yolo OU
        # /yolo de session OU mode == off) et il est teste AVANT les branches
        # cron / single_query / unattended, donc il coupe aussi les refus par
        # defaut en contexte headless (cron_mode etc. deviennent sans objet).
        # Les outils web (web_search / web_extract) ne passaient deja par
        # aucun prompt : cette cle ne concerne que les commandes shell
        # dangereuses (rm -r, chmod 777, bash -c, curl | sh, systemctl...).
        # Restent actifs malgre "off" : le blocklist hardline code-shippe
        # (tools/approval.py::UNRECOVERABLE_BLOCKLIST) et les regles
        # approvals.deny (vides ici) — aucun override possible.
        approvals = {
          mode = "off";
        };

        # --- Télémétrie « shared metrics » : réponse explicite « Non merci » ---
        # Marc ne partage pas les stats (23/10/2026). L'offre (bandeau Desktop,
        # bannière dashboard) est considérée répondue dès qu'UNE des deux clés
        # est écrite EXPLICITEMENT dans config.yaml — le défaut (tout
        # désactivé) n'est PAS une réponse, donc la question revient à chaque
        # session tant que ces clés sont absentes.
        #   enabled=false + send=false  -> réponse « Non merci »
        #   offer_version=2             -> évite la « re-ask » unique prévue
        #     pour les réponses « off » antérieures au fix type-ahead
        #     (consent_state : une réponse off sans offer_version=2 est
        #     reposée une fois). Avec ces trois clés, decided=true partout.
        # Aucune donnée n'est collectée ni envoyée avec ces valeurs ; pour
        # changer d'avis : éditer ce bloc + rebuild (install nix-managed).
        telemetry = {
          shared_metrics = {
            enabled = false;
            send = false;
            offer_version = 2;
          };
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
        # `matrix-loop-emoji` : emoji 🔄 en fin de chaque message Matrix, et une
        # reaction 🔄 d'un utilisateur autorise sur un message du bot renouvelle
        # la session (chemin de /new, sans confirmation). Code vendorise dans
        # services/hermes/plugins/matrix-loop-emoji et pose par hermesHomeFiles.
        plugins = {
          enabled = [ "herdr-agent-state" "matrix-loop-emoji" ];
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
              # Nino : Opus 5.5 (route native `claude-opus-5-5`, tirets ; la forme
              # `claude-opus-5.5` est rejetée par le CLI). Variante [1m] = 1M de
              # contexte ; effort max via reasoning_overrides.
              # Nino : DeepSeek v4.1 Flash (OpenRouter), 1er secours par defaut.
              "!zOyDctBWcuFCJKJINI:matrix.marcpartensky.com" = {
                provider = "openrouter";
                model = "deepseek/deepseek-v4.1-flash";
              };
              # Zoé : DeepSeek v4.1 Flash (OpenRouter), 1er secours par defaut.
              "!sylSYxsYVJRknngRnF:matrix.marcpartensky.com" = {
                provider = "openrouter";
                model = "deepseek/deepseek-v4.1-flash";
              };
              "!JgWSzbTBCRPEOQTAZi:matrix.marcpartensky.com" = {
                provider = "claude-subscription-directsdk-experimental";
                model = "claude-sonnet-5[1m]";
              };
              "!ANuTSqPZhKzHOpvXhB:matrix.marcpartensky.com" = {
                provider = "claude-subscription-directsdk-experimental";
                model = "claude-sonnet-5[1m]";
              };
              "!myvmCEICVnXNIOxHSQ:matrix.marcpartensky.com" = {
                provider = "claude-subscription-directsdk-experimental";
                model = "claude-sonnet-5[1m]";
              };
              "!ABhBVVGeBoBEvuiFSY:matrix.marcpartensky.com" = {
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

        # --- Entree automatique dans le vocal Discord ---
        # Hermes n'entre en vocal que sur `/voice join` ; ce plugin ajoute un
        # handler natif discord.py sur l'adaptateur Discord (ctx.
        # register_platform_handler) : un membre autorise rejoint un salon vocal
        # -> le bot s'y connecte, et il sort quand plus personne n'y est. Il
        # branche `adapter.join_voice_channel(text_channel_id=...)`, indispensable
        # car sans salon texte lie la transcription est jetee.
        (pkgs.runCommandLocal "discord-auto-join" {} ''
          mkdir -p $out
          cp ${./plugins/discord-auto-join/plugin.yaml} $out/plugin.yaml
          cp ${./plugins/discord-auto-join/__init__.py} $out/__init__.py
        '')
      ];

      # --- Hook de gateway : pont Matrix -> Gotify ---
      # Vendorise ici, installe dans $HERMES_HOME/hooks/gotify-notify (extension
      # point "trusted by placement" : le gateway charge au demarrage tout
      # dossier contenant HOOK.yaml + handler.py, donc un switch suffit a
      # l'activer). Le handler lit le jeton d'application Gotify provisionne par
      # services/gotify-matrix et pousse les reponses publiees dans la salle du
      # pont. Details et filtres : services/hermes/hooks/gotify-notify/handler.py.
      hermesHomeFiles = {
        "hooks/gotify-notify/HOOK.yaml" = ./hooks/gotify-notify/HOOK.yaml;
        "hooks/gotify-notify/handler.py" = ./hooks/gotify-notify/handler.py;

        # Plugin matrix-loop-emoji : pose directement dans $HERMES_HOME/plugins/
        # sous son nom d'origine (pas de prefixe nix-managed-), pour qu'il soit
        # charge comme plugin "user" et non en doublon via extraPlugins.
        "plugins/matrix-loop-emoji/plugin.yaml" = ./plugins/matrix-loop-emoji/plugin.yaml;
        "plugins/matrix-loop-emoji/__init__.py" = ./plugins/matrix-loop-emoji/__init__.py;
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

    # --- MCP Gitea : serveur officiel (gitea.com/gitea/gitea-mcp) ---
    # Nécessite un PAT Gitea (Settings -> Applications -> Generate Token)
    # scopes: repo, admin:org, admin:user, notification, user, write:package, read:package
    services.hermes-agent.mcpServers.gitea = {
      command = "gitea-mcp";
      args = [ "-t" "stdio" ];
      env = {
        GITEA_HOST = "https://git.marcpartensky.com";
        GITEA_ACCESS_TOKEN_FILE = config.sops.secrets."gitea-mcp/pat".path;
      };
      timeout = 60;
    };

    # --- MCP Beeper : API locale de Beeper Desktop (loopback 23373) ---
    # L'entrée n'existait qu'impérativement dans config.yaml, avec un token en
    # dur (29 caractères) qui ne correspond plus à BEEPER_ACCESS_TOKEN et prend
    # un 401. Déclarée ici : le token est lu depuis l'environnement (.env /
    # sops hermes_env), jamais recopié dans le dépôt. L'URL LAN rend le lien
    # cliquable depuis Hermes Desktop (module services/mcp-lan-access).
    services.hermes-agent.mcpServers.beeper = {
      url =
        if config.services.mcp-lan-access.enable
        then "http://${config.services.mcp-lan-access.host}:23373/v0/mcp"
        else "http://127.0.0.1:23373/v0/mcp";
      headers.Authorization = "Bearer \${env:BEEPER_ACCESS_TOKEN}";
      timeout = 60;
    };

    # --- MCP Hinge : pilotage de l'app sur le telephone de marc -----------------
    # Le telephone fait tourner android-remote-control-mcp sur son 127.0.0.1:8080.
    # On l'atteint par le sshd du tel (maintenu par phone-up/watchdog cote tel).
    # Le forward est un service ici, jamais un `ssh -N -L` de session : il survit
    # aux deconnexions et redemarre seul. Cote client, hinge_mcp.py parle stdio.
    systemd.services.phone-mcp-tunnel = {
      description = "Forward loopback vers le MCP du telephone (ssh -L 18080)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "hermes";
        Group = "users";
        Restart = "always";
        RestartSec = 10;
        ExecStart = "${pkgs.openssh}/bin/ssh -N -T -o ExitOnForwardFailure=yes "
          + "-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes "
          + "-L 127.0.0.1:18080:127.0.0.1:8080 phone";
      };
    };

    services.hermes-agent.mcpServers.hinge = {
      command = "${pkgs.python3}/bin/python3";
      args = [ "/var/lib/hermes/workspace/hinge-re/hinge_mcp.py" ];
      timeout = 300;
    };

    # --- MCP iprep : score de reputation d'IP agrege ---------------------------
    # Serveur stdio ecrit a la main (stdlib python, aucune dependance) qui
    # interroge les sources publiques sans cle (Scamalytics, AlienVault OTX,
    # StopForumSpam, GreyNoise community, Project HoneyPot, DNSBL) et renvoie
    # un risque normalise 0-100 par source + la moyenne. AbuseIPDB et
    # IPQualityScore s'ajoutent si ABUSEIPDB_API_KEY / IPQS_API_KEY sont
    # fournies dans l'environnement (facultatif, sans cle ils sont ignores).
    services.hermes-agent.mcpServers.iprep = {
      command = "${pkgs.python3}/bin/python3";
      args = [ "/var/lib/hermes/workspace/iprep-mcp/server.py" ];
      # Le MCP lit quatre sources dans le vrai Chrome du Mac : il a besoin de
      # node pour driver le CDP et du tunnel loopback ci-dessous.
      env.IPREP_NODE = "${pkgs.nodejs}/bin/node";
      timeout = 300;
    };

    # Tunnel loopback vers le CDP du Chrome "agent" du Mac (9222 cote Mac,
    # 19222 cote tower). Le MCP iprep s'en sert pour les quatre sources que
    # Cloudflare ferme a curl et au Chromium headless : AbuseIPDB,
    # IPQualityScore, Cisco Talos, check.spamhaus.org. Meme pattern que
    # phone-mcp-tunnel : un service, pas un `ssh -N -L` de session, pour qu'il
    # survive aux deconnexions. Hote `mac` (tunnel inverse autossh du Mac), donc
    # valable aussi hors du LAN de tower.
    systemd.services.mac-cdp-tunnel = {
      description = "Tunnel loopback vers le CDP du Chrome agent du Mac";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "hermes";
        Group = "users";
        Restart = "always";
        RestartSec = 15;
        ExecStart = "${pkgs.openssh}/bin/ssh -N -T -o ExitOnForwardFailure=yes "
          + "-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes "
          + "-o BatchMode=yes -L 127.0.0.1:19222:127.0.0.1:9222 mac";
      };
    };

    # --- MCP phonerep : score de reputation de NUMERO DE TELEPHONE agrege ------
    # Meme convention que iprep (risque 0-100 par source + moyenne, 0 = propre).
    # Sources sans cle : veriastra (spam score + plaintes FTC, validite et
    # operateur), spamcalls, RoboKiller, shouldianswer, Nomorobo,
    # 800notes/whocallsme. phonenumbers (paquet nix) donne la normalisation
    # E.164 et le type de ligne hors ligne. VERIASTRA_API_KEY et IPQS_API_KEY
    # sont optionnelles : sans cle ces sources sont ignorees et signalees.
    # tellows et la page gratuite IPQS restent a lire dans un vrai navigateur.
    services.hermes-agent.mcpServers.phonerep = {
      command = "${pkgs.python3.withPackages (p: [ p.phonenumbers ])}/bin/python3";
      args = [ "/var/lib/hermes/workspace/phonerep-mcp/server.py" ];
      timeout = 180;
    };

    # --- MCP Pangolin : API d'intégration self-hosted ---
    # L'API v1 (clé Bearer, clé "hermes" de la table apiKeys du dashboard) est
    # activée par le flag enable_integration_api de services/pangolin et
    # répond sur api.marcpartensky.com/v1 (routeur traefik dédié) ; PAS sur
    # pangolin.vps.marcpartensky.com qui ne sert que le dashboard. Le script
    # (services/hermes/pangolin-mcp.py) relit la clé à chaque appel ; un
    # process déjà lancé garde son ancienne PANGOLIN_BASE_URL jusqu'au
    # redémarrage de hermes.

    # --- MCP voix (TTS) : serveur HTTP sur le PORTABLE, joint par le tailnet ---
    # Les moteurs (Phonon, Kokoro en CPU ; OmniVoice, Ming, Chatterbox, Breeze
    # en GPU), les poids et la RTX 3060 sont sur le portable : toute generation
    # de voix y reste, quelle que soit la machine qui pilote l'agent. Le
    # serveur vit dans services/tts-mcp (laptop) et garde les modeles chauds ;
    # timeout large car un moteur GPU charge son modele avant de parler.
    # Adresse : tailscale du portable (100.64.0.4), port ouvert sur
    # tailscale0 seulement.
    services.hermes-agent.mcpServers.tts = {
      url = "http://100.64.0.4:8092/mcp";
      timeout = 900;
    };

    # --- MCP Vaultwarden : temporairement désactivé (blocage sops manifest) ---
    # services.hermes-agent.mcpServers.vaultwarden = {
    #   command = "vaultwarden-mcp";

    # --- node/npm requis pour le serveur GitHub (npx) ---
    # (ajouté dans extraPackages plus haut : l'option n'accepte qu'une définition)

    # --- ollama : embeddings locaux pour mem0 ---
    # nomic-embed-text = 768 dims, supporté par le plugin mem0. CPU suffit.
    services.ollama = {
      enable = true;
      loadModels = ["nomic-embed-text"];
    };

    # claude aussi dispo pour marc et les sessions CLI de hermes
    # (le python3 SYSTEME est déjà ajouté hors du bloc ci-dessus, cf. en haut de
    # `config` : requis par le probe SSH de Hermes Desktop)

    sops.secrets."hermes_env" = {};

    # Clé du compte DeepSeek direct, en clair pour l'agent : son contenu est un
    # dotenv (« DEEPSEEK_API_KEY=... ») ajouté aux environmentFiles de l'unité,
    # donc lue par le provider INTÉGRÉ deepseek (model.provider ci-dessus).
    # Même fichier que
    # le solde affiché par le dashboard d'usage (secrets/deepseek.yml).
    sops.secrets."hermes_deepseek_env" = {
      key = "hermes_deepseek_env";
      sopsFile = ../../secrets/deepseek.yml;
    };

    # Clé du listener API Server du profil default (clé "hermes_api_server_env"
    # du fichier sops, valeur = contenu dotenv "API_SERVER_KEY=..."). Même valeur
    # que HERMES_BRIDGE_API_KEY côté services/discord-bot, qui l'envoie en Bearer :
    # le pont Discord et l'API server partagent donc LA MÊME clé, chiffrée une
    # seule fois dans secrets/discord-hermes-bridge.yml.
    sops.secrets."hermes_api_server_env" = {
      # TODO(marc) : renommer la clé hermes_discord_bridge_env -> hermes_api_server_env
      # dans secrets/discord-hermes-bridge.yml (sops) quand tu as la clé age sous la
      # main ; hermes n'a pas accès en déchiffrement pour le faire lui-même.
      key = "hermes_discord_bridge_env";
      sopsFile = ../../secrets/discord-hermes-bridge.yml;
    };

    # Le secret ci-dessus est une clé NUE : rendue en .env par concaténation, elle
    # n'aurait pas de nom de variable. Le template ci-dessous en fait un vrai
    # dotenv (API_SERVER_KEY=...), consommé par l'unité hermes-agent.
    sops.templates."hermes-api-server.env".content = ''
      API_SERVER_KEY=${config.sops.placeholder."hermes_api_server_env"}
    '';

    # Clé API du MCP Pangolin (clé racine "pangolin_api_key" de
    # secrets/common.yml, valeur = clé "hermes" créée dans le dashboard).
    # owner hermes + 0400 : le MCP est un process de l'agent et relit ce
    # fichier lui-même à chaque appel HTTP. L'ancienne déclaration pointait
    # une clé imbriquée pangolin.api_key inexistante ("the key 'pangolin'
    # cannot be found" faisait échouer tout switch : laissée hors service
    # jusqu'à maintenant).
    sops.secrets."pangolin_api_key" = lib.mkIf config.services.hermes.enableAgent {
      sopsFile = ../../secrets/common.yml;
      owner = "hermes";
      mode = "0400";
    };

    # Token Matrix du bot (@hermes) — clé "hermes_matrix_env" du fichier sops,
    # valeur = contenu dotenv (MATRIX_ACCESS_TOKEN=...) fusionné dans .env.
    # Déclaré uniquement là où l'option est active : les destinataires du fichier
    # n'incluent pas anywhere/laptop, y déclarer le secret ferait échouer
    # l'activation (setupSecrets « 0 successful groups required »).
    sops.secrets."hermes_matrix_env" = lib.mkIf config.services.hermes.enableMatrixToken {
      sopsFile = ../../secrets/hermes-matrix.yml;
    };

    # Token du bot Discord dédié (voix + texte) — clé "hermes_discord_env" du
    # fichier sops, valeur = contenu dotenv (DISCORD_BOT_TOKEN=...) fusionné
    # dans .env. Déclaré uniquement là où l'option est active, même raison que
    # pour le token Matrix.
    sops.secrets."hermes_discord_env" = lib.mkIf config.services.hermes.enableDiscordToken {
      sopsFile = ../../secrets/hermes-discord.yml;
    };

    # --- Accès SSH direct de hermes (tower) vers les autres hôtes qui importent
    # ce module (laptop, anywhere) : défini en haut de `config` (utilisateur
    # hermes + clé + sudo), commun à tous les hôtes.
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

    # --- Le gateway ne doit jamais etre tue ni affame ---
    # Sans ce bloc, hermes-agent vit dans system.slice au poids par defaut
    # (100), a egalite avec un build nix, sans protection memoire.
    #
    #  - hermes.slice CPUWeight=2000 : sous contention il passe avant tout le
    #    reste de system.slice (poids 100), soit 20x la priorite par defaut.
    #    Un POIDS, pas un quota : machine libre il prend tout le CPU, et rien
    #    ne le bride jamais. (10000 donnait ~91 % du CPU sous contention et
    #    tombait les builds a ~0,2 % : trop brutal, 2000 suffit largement.)
    #  - MemoryMin/MemoryLow : plancher cgroup v2, sa memoire n'est plus
    #    recuperable par un autre cgroup sous pression. Surtout PAS de
    #    MemoryMax : ca le rendrait tuable depuis l'interieur de son cgroup.
    #  - OOMScoreAdjust=-1000 : le killer OOM du noyau l'exclut.
    #  - StartLimitIntervalSec=0 : systemd ne renonce plus jamais a relancer.
    #
    # Les ENFANTS heritent du cgroup : les serveurs MCP et les sous-processus
    # des taches (builds, navigateurs, scripts) sont bornes par ce meme poids.
    systemd.slices.hermes = {
      description = "Hermes Agent (priorite interactive)";
      sliceConfig = {
        CPUWeight = 2000;
        IOWeight = 1000;
        # Reservation materielle : les deux threads du coeur physique 6
        # (cpu12, cpu13) sont a Hermes, exclus de background.slice. Meme sous
        # un build 14 threads, le gateway garde un coeur physique entier.
        # Un POIDS seul ne garantit rien en valeur absolue ; cpuset, si.
        # Contrepartie assumee : les sous-processus des taches (builds,
        # navigateurs lances par un agent) heritent du cpuset et tournent sur
        # ces 2 threads. Le travail lourd doit partir sur la flotte (Windmill).
        AllowedCPUs = "12-13";
      };
    };

    # `member` n'exclut personne : system.slice/user.slice peuvent encore
    # tourner sur 12-13. On promeut la slice en partition root cgroup v2, ce
    # qui rend ces 2 threads exclusifs a Hermes et a ses descendants. Aucun
    # parametre de boot (isolcpus) necessaire. Contrepartie : 12-13 ne sont
    # plus utilisables par le reste du systeme, meme quand Hermes est idle.
    systemd.services.hermes-cpuset = {
      description = "Promeut hermes.slice en partition root cpuset (12-13 exclusifs)";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes.slice" ];
      before = [ "hermes-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "hermes-cpuset" ''
          set -eu
          cg=/sys/fs/cgroup/hermes.slice
          echo "12-13" > "$cg/cpuset.cpus.exclusive"
          echo "root" > "$cg/cpuset.cpus.partition"
        '';
      };
    };
    systemd.services.hermes-agent = {
      # Un rebuild NixOS ne doit pas couper le gateway : ses taches vivent
      # dedans. restartIfChanged=false => switch-to-configuration met a jour
      # le fichier d'unite mais ne redemarre pas le process en cours ; la
      # nouvelle config s'applique au prochain demarrage manuel.
      restartIfChanged = false;
      serviceConfig = {
        Slice = "hermes.slice";
        OOMScoreAdjust = -1000;
        MemoryMin = "1G";
        MemoryLow = "2G";
        ManagedOOMPreference = "avoid";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };
    # Le backend sert le desktop et le terminal web : meme traitement.
    systemd.services.hermes-backend = {
      restartIfChanged = false;
      serviceConfig = {
        Slice = "hermes.slice";
        OOMScoreAdjust = -1000;
        MemoryMin = "256M";
        MemoryLow = "512M";
        ManagedOOMPreference = "avoid";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    # --- Opus pour la voix Discord ---
    # L'adaptateur Discord de Hermes (plugins/platforms/discord/adapter.py) charge
    # libopus via ctypes.util.find_library("opus"), qui sur NixOS ne trouve rien :
    # pas de /etc/ld.so.cache, et le repli gcc/ld échoue faute de binaires. Le
    # repli `ld -L <LD_LIBRARY_PATH> -lopus` + `objdump` fonctionne avec binutils
    # sur le PATH (extraPackages), et il faut LD_LIBRARY_PATH DANS l'environnement
    # du process dès le démarrage : dlopen("libopus.so.0") utilise la valeur lue
    # par ld.so au lancement, une variable ajoutée plus tard via .env ne suffit
    # pas. C'est l'env de l'UNITÉ systemd (l'option `environment` du module, elle,
    # n'écrit que $HERMES_HOME/.env).
    # Vérifié : find_library -> libopus.so.0, discord.opus.is_loaded() -> True,
    # Decoder/Encoder opus instanciables.
    systemd.services.hermes-agent.environment.LD_LIBRARY_PATH = "${pkgs.libopus}/lib";

    # --- Desktop plugin: vim-keybindings (déclaratif, géré par nix) ---
    # Crée le plugin dans /var/lib/hermes/.hermes/desktop-plugins/vim-bindings/
    # via tmpfiles + service oneshot au démarrage du service hermes.
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes/.hermes/desktop-plugins 0755 hermes hermes -"
      "d /var/lib/hermes/.hermes/desktop-plugins/vim-bindings 0755 hermes hermes -"
      "a /home/marc - - - - u:hermes:--x,m::--x"
      "a /home/marc/git - - - - u:hermes:--x,m::r-x"
    ];

        # --- vim-bindings plugin : DISABLED (JS heredoc parsing issues in Nix)
        # systemd.services.hermes-vim-bindings-plugin = { ... };
    })

    # --- MCP Nextcloud : voir services/nextcloud-mcp (single_user_basic, loopback) ---
  ];
}
