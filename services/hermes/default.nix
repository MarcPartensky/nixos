{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # claude-code pinned newer than nixpkgs 26.05 (2.1.223).
  # The API rejects Opus 5.5 models below 2.1.280:
  #   "API Error: 400 Claude Code 2.1.223 does not support this model;
  #    version 2.1.280 or newer is required."
  # Fable 5.2 (claude-fable-5-2) only appears in the CLI selector from 2.1.321
  # (upstream CHANGELOG), hence the 2.1.325 pin: without it the provider
  # claude-subscription-directsdk cannot offer the model, whatever its config.
  # The nixpkgs package takes its manifest (version + per-platform checksums)
  # as an argument: we pass it the one published by Anthropic for the stable channel
  # (https://downloads.claude.ai/claude-code-releases/2.1.325/manifest.json),
  # copied as-is into ./claude-code-manifest.json. Update = recopy the
  # manifest of a newer version, nothing else.
  claudeCode = pkgs.claude-code.override {
    manifest = lib.importJSON ./claude-code-manifest.json;
  };

  # MCP Pangolin: no more package here. The server is mounted by
  # modules/nixos/mcp-host directly from ./pangolin-mcp.py (entry
  # `pangolin` of profiles/tower/configuration.nix), so the binary
  # writePython3Bin was no longer useful and was no longer referenced any
  # where: it only evaluated a python package on each host eval.
  # Upstream hermes-agent fix (services/hermes/hermes-agent-managed-home.py):
  # secure_parent_dir() in hermes_constants.py chmods the parent of credential
  # files (the hermes home itself: auth.json lives at its root) to 0700 on every
  # save, with no managed-install carve-out -- unlike apply_secure_dir_policy()
  # and ensure_private_store(), which both skip managed installs by design. On
  # this host the home is group-shared with marc (0750 + ACLs, cf.
  # profiles/tower/configuration.nix), so every credential save silently
  # re-locked him out; observed live 2026-11-25 02:06:59 (auth.json save, mode
  # 750 -> 700, gateway unaffected). The fixer rewrites the file so the same
  # carve-outs win (managed installs, HERMES_HOME_MODE). Its anchor must match
  # exactly once or the build fails loudly: on an upstream bump that moves the
  # code, update the fixer.
  #
  # WHERE the file lives decides how to patch it. Upstream's package is only the
  # wrapper (bin/, share/, ui-tui/); the Python tree lives in a separate venv
  # derivation, so a postFixup on the package never sees hermes_constants.py
  # (observed: "expected exactly one hermes_constants.py ... found []"). This
  # derivation ships a patched copy as a Python module and hands it to
  # extraPythonPackages, the upstream hook: the wrapper puts those entries on
  # PYTHONPATH, which Python searches BEFORE the venv's site-packages (verified
  # on this host: a PYTHONPATH copy of hermes_constants.py wins over the venv's).
  # toPythonModule keeps the package in the venv's own Python family, which is
  # what the module filters extraPythonPackages on.
  hermesConstantsManagedHome =
    config.services.hermes-agent.package.python.pkgs.toPythonModule (
      pkgs.runCommand "hermes-constants-managed-home"
        {
          nativeBuildInputs = [ pkgs.python3 ];
        }
        ''
          site=$out/${config.services.hermes-agent.package.python.sitePackages}
          mkdir -p "$site"
          cp ${inputs.hermes-agent}/hermes_constants.py "$site/hermes_constants.py"
          chmod u+w "$site/hermes_constants.py"
          python3 ${./hermes-agent-managed-home.py} $out
        ''
    );
in {
  # Option: the Matrix token of the @hermes bot (hermes_matrix_env key of
  # secrets/hermes-matrix.yml). The recipients of this sops file do
  # NOT contain the age keys of anywhere/laptop: only enable it on
  # hosts able to decrypt it (tower), otherwise the activation (setupSecrets)
  # fails and hermes-agent starts without its env file.
  options.services.hermes.enableMatrixToken = lib.mkEnableOption ''
    the Matrix token of the @hermes bot (secrets/hermes-matrix.yml, recipients = tower only)
  '';

  # Option: the token of Hermes's dedicated Discord bot (native voice + text, profile
  # `discord-bridge`). Same constraint as enableMatrixToken: the recipients
  # of secrets/hermes-discord.yml do not include anywhere/laptop, so only
  # enable it on tower, otherwise the activation (setupSecrets) fails and
  # hermes-agent starts without its env file.
  options.services.hermes.enableDiscordToken = lib.mkEnableOption ''
    the Discord token of the Hermes bot (secrets/hermes-discord.yml, recipients = tower only)
  '';

  # Option: the Gitea MCP server. It reads secrets/gitea-mcp.yml (recipients =
  # tower only) via GITEA_ACCESS_TOKEN_FILE: importing it elsewhere would
  # reference an undeclared secret (eval error) or an undecryptable one.
  options.services.hermes.enableGiteaMcp = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Declare the Gitea MCP server (secrets/gitea-mcp.yml, tower only).";
  };

  # Option: the Gemini key (secrets/hermes-gemini.yml, recipients = tower
  # only). True on tower, false on a fallback host that cannot
  # decrypt this file: without it, setupSecrets fails and nothing is written.
  options.services.hermes.enableGeminiToken = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Declare the Gemini key (secrets/hermes-gemini.yml, tower only).";
  };

  # Option: launch the hermes-agent gateway (chat) on this host. Default active
  # everywhere this module is imported. Turning it off (e.g. racknerd VPS, where chat
  # is inert: no Matrix/Discord token, DirectSDK model without claude
  # login) removes the service, ollama, claude-code (unfree) and the MCPs, but
  # KEEPS the hermes user + SSH key + sudo nixos-rebuild (remote access).
  options.services.hermes.enableAgent = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Launch the hermes-agent gateway (chat) on this host.";
  };

  # CPUs reserved EXCLUSIVELY for hermes.slice (cgroup v2 root partition).
  # null = no isolation. The value depends on the host hardware (tower:
  # "12-15", i.e. the 2 physical cores 6 and 7), it cannot be guessed: a
  # laptop with 12 threads has no cpu12-15, and an invalid value prevents
  # hermes-agent from starting (AllowedCPUs rejected by systemd). To be declared per
  # host, then.
  options.services.hermes.cpuIsolation = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "12-15";
    description = "CPUs reserved exclusively for hermes.slice (null = no isolation).";
  };

  # hermes no longer has direct access to nixos-rebuild: only the wrapper
  # gated (refuses --impure + serialization lock), see the module.
  imports = [
    ../../modules/nixos/nixos-rebuild-gated
    # Compilation ban for hermes on tower (marc's policy,
    # 25/11/2026): /etc/hermes-no-compile shims + shell block in
    # /var/lib/hermes/.bashrc. The module is limited to tower (the deck, though, must
    # be able to compile).
    ../../modules/nixos/hermes-no-compile
  ];

  config = lib.mkMerge [
    {
    # --- hermes user (remote SSH access + sudo nixos-rebuild) ---
    # Defined here for ALL hosts, even when the gateway is off
    # (enableAgent = false): it is through this user that hermes@tower
    # deploys and diagnoses remote hosts. The hermes-agent module must
    # not recreate it (createUser = false).
    users.groups.hermes = {};
    users.users.hermes = {
      isSystemUser = true;
      group = "hermes";
      home = "/var/lib/hermes";
      createHome = true;
      shell = pkgs.bashInteractive;
      # subuid/subgid range for rootless podman (agents: tool containers
      # throwaway). Without it, `podman pull` fails at unpack on
      # "potentially insufficient UIDs or GIDs available in user namespace".
      # 200000 to avoid overlapping marc's range (100000:65536).
      subUidRanges = [{ startUid = 200000; count = 65536; }];
      subGidRanges = [{ startGid = 200000; count = 65536; }];
      # Both agent keys of the mesh: hermes@tower and hermes@laptop. Every host
      # running this module accepts either one, so the agent can hop from any
      # machine to any other (tower, laptop) without a separate authorization.
      # nix-builder@tower: key pair DEDICATED to tower's nix-daemon for
      # distributed builds (nix.buildMachines of profiles/tower). Authorized here in a
      # declarative way (so via /etc/ssh/authorized_keys.d/hermes, which sshd reads
      # even when the home is group-writable): in ~/.ssh/authorized_keys,
      # sshd StrictModes silently ignored it when /var/lib/hermes was
      # in 2770 (observed on 25/11/2026 on the laptop -> "Permission denied").
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTNk2eJYoD87QP/Ajg6iCX/EwYCjVVvoTfTAFqh2qnW hermes@laptop"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItlIA6k7s5q58FQBvof2aJ5ZljvA2vhhhRJqap6uVCb nix-builder@tower"
      ];
    };
    services.hermes-agent.createUser = false;

    # SYSTEM python3 (not the one from the sealed venv): the SSH startup probe of
    # Hermes Desktop runs `python3 -c ...` on the remote machine to read
    # ~/.hermes-update-in-progress. Without python3 in the ssh PATH, ANY
    # Desktop SSH connection fails with "Could not prove that the remote Hermes install
    # is clear for SSH startup." (verified on 27/09/2026)
    # claude-code (unfree) is added ONLY if the gateway runs on this host:
    # it is only used by the claude-subscription-directsdk provider (Matrix).
    environment.systemPackages = [pkgs.python3] ++ lib.optionals config.services.hermes.enableAgent [claudeCode];

    # --- Direct SSH access from hermes (tower) to the other hosts that import
    # this module (laptop, anywhere): opens a shell (et-session + zellij) to
    # act/build directly on the machine, without copy-paste by marc.
    # Same key as the one already placed for root on anywhere (25/09/2026).
    security.sudo.extraRules = [
      # marc: direct access kept (he owns the machine).
      {
        users = ["marc"];
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nixos-rebuild/bin/nixos-rebuild";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/nixos-rebuild-gated";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nixos-rebuild-gated/bin/nixos-rebuild-gated";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # --- git: nixos-rebuild runs as root even when launched by hermes ---
    # without this, libgit2 refuses to open a flake owned by marc
    programs.git = {
      enable = true;
      config.safe.directory = ["/home/marc/git/nixos"];
    };
    }

    # --- hermes-agent gateway (chat): active by default, switchable per host ---
    (lib.mkIf config.services.hermes.enableAgent {
    # --- declaration of postgresql needs ---
    # nixos automatically merges these lists with those of the postgres module
    services.postgresql.ensureDatabases = ["hermes"];
    services.postgresql.ensureUsers = [
      {
        name = "hermes";
      }
    ];

    # --- service hermes ---
    services.hermes-agent = {
      enable = true;

      # Upstream hermes-agent fix: secure_parent_dir() in hermes_constants.py
      # re-locks the group-shared home on every credential save. The patch ships
      # as hermesConstantsManagedHome (let block above), through
      # extraPythonPackages -- NOT as a postFixup here: the file lives in the
      # upstream venv, not in this package's $out, so a postFixup can never see
      # it. See the comment above that derivation for the full story.
      environmentFiles =
        [ config.sops.secrets."hermes_env".path ]
        ++ lib.optional config.services.hermes.enableMatrixToken config.sops.secrets."hermes_matrix_env".path
        ++ lib.optional config.services.hermes.enableDiscordToken config.sops.secrets."hermes_discord_env".path
        # API_SERVER_KEY: the encrypted value is the BARE KEY (64 hex), not a
        # dotenv "API_SERVER_KEY=...". The module only CONCATENATES the
        # environmentFiles into $HERMES_HOME/.env, so the key arrived alone on
        # a line without a variable name: API_SERVER_KEY stayed empty,
        # the api_server refuses to start without a usable key (min 16 chars), and
        # the Discord bridge (services/discord-bot -> 127.0.0.1:8642) no longer had
        # a listener. A sops-nix template prefixes the key.
        ++ [ config.sops.templates."hermes-api-server.env".path ]
        # DEEPSEEK_API_KEY (direct account), consumed by the custom
        # provider deepseek: without this file the provider exists but the call goes
        # out without a token and returns 401.
        ++ [
          config.sops.secrets."hermes_deepseek_env".path
          # MODEL_API_KEY (Meta Model API account, INTEGRATED meta-ai provider).
          # Same mechanism, dotenv content. REAL key set on 20/11/2026
          # (48 chars, LLM_ prefix; catalog muse-spark/wonder/ember + sam-3.1).
          # Rotation: sops set secrets/meta.yml, never the file by hand.
          config.sops.secrets."hermes_meta_env".path
        ]
        # GOOGLE_API_KEY (Google AI Studio key, INTEGRATED gemini provider).
        # dotenv content. Verified on 20/11/2026: 65 models listed by
        # /v1beta/models, gemini-3.8-flash and gemini-4-argon available.
        # Rotation: sops set secrets/hermes-gemini.yml, never the file by
        # hand. OPTIONAL: secrets/hermes-gemini.yml only has the age key of
        # tower as recipient, so any other host (fallback laptop)
        # must turn off this flag, otherwise setupSecrets aborts its activation.
        ++ lib.optional config.services.hermes.enableGeminiToken
        config.sops.secrets."hermes_gemini_env".path;
      addToSystemPackages = true;

      # sealed nix venv -> mem0 deps (mem0ai) installed at runtime in a durable target
      environment.HERMES_LAZY_INSTALL_TARGET = "/var/lib/hermes/.hermes/lazy-python";

      # --- Matrix: @hermes bot (Element + mautrix bridges) ---
      environment.MATRIX_HOMESERVER = "https://matrix.marcpartensky.com";
      environment.MATRIX_USER_ID = "@hermes:matrix.marcpartensky.com";
      # bridge rooms = E2EE encrypted (encryption.default=true on the mautrix-signal side)
      environment.MATRIX_E2EE_MODE = "required";
      # bridge room = 3+ members (bridge bot included) -> not classified as DM:
      # reply without mention, and no auto-thread (bridges flatten threads)
      environment.MATRIX_REQUIRE_MENTION = "false";
      environment.MATRIX_AUTO_THREAD = "false";
      # @marc + his Signal ghost (mautrix-signal)
      environment.MATRIX_ALLOWED_USERS = "@marc:matrix.marcpartensky.com,@signal_ad927dda-4064-48ff-8652-01a0d71005e4:matrix.marcpartensky.com";

      # --- Discord: NATIVE DISABLED (see profiles/tower: enableDiscordToken) ---
      # Historically: dedicated bot (voice + text) on the `discord-bridge` profile.
      # Today Discord is served by services/discord-bot (marc's bot) which
      # calls the API server of the default profile under /p/discord-bridge/. The
      # native platform therefore stays disabled: its sops token is a
      # placeholder and discord.py is not in the sealed venv, which
      # made it show up "down" permanently. Allowlist kept for the day
      # it gets re-enabled (@marc only, Discord id).
      environment.DISCORD_ALLOWED_USERS = "478552571510915072";

      # --- Opus (Discord voice): see the "Opus" block below, at the `config` level
      # (the process env is set on the systemd unit, not via `environment`, which
      # only writes $HERMES_HOME/.env) ---

      # --- API Server (OpenAI-compatible): A SINGLE listener per host ---
      # Hermes's topology is "one gateway per host serving all profiles"
      # (multiplex). A secondary profile requesting its API server does NOT get
      # its own port: the default profile's listener serves it under
      # /p/<profile>/... (gateway log: "api_server is served by the default
      # profile's listener at /p/<profile>/ - not starting a second listener").
      # This is what the Discord bridge consumes: services/discord-bot calls
      # http://127.0.0.1:8642/p/discord-bridge/v1/chat/completions.
      # Bind loopback only, mandatory key (sops), never opened to
      # the firewall, never routed by Pangolin.
      environment.API_SERVER_ENABLED = "true";
      environment.API_SERVER_PORT = "8642";

      # psycopg2 built by nix (avoids the manylinux psycopg2-binary wheel)
      # numpy is NO LONGER LISTED HERE: since the addition of "stt-whisper" (onnxruntime ->
      # numpy 2.4.3) the sealed venv provides it itself, and the build of the hermes package
      # FAILS if a package of extraPythonPackages duplicates the venv ("plugin package
      # "numpy" collides with a package in hermes sealed venv"). The venv's numpy
      # (built by nix) also serves runtime lazy-installs: manylinux wheel broken
      # on NixOS (libstdc++.so.6 missing), hence its former presence here.
      # WARNING: the packages MUST be from the venv interpreter. The
      # python family is driven by pm/lock.json (nix/pythonLock.nix, here 3.14); a
      # package from another family is silently filtered by hasPythonModule
      # -> PYTHONPATH without the package. package.python.pkgs follows the venv.
      # hermesConstantsManagedHome (let block above) carries the patched
      # hermes_constants.py: PYTHONPATH precedes the venv's site-packages, so this
      # copy is the one imported at runtime.
      extraPythonPackages =
        with config.services.hermes-agent.package.python.pkgs;
        [ psycopg2 ]
        ++ [ hermesConstantsManagedHome ];

      # pyproject dep groups resolved by uv INSIDE the sealed venv (no
      # PYTHONPATH):
      # - "matrix": mautrix[encryption] + python-olm (embedded libolm)
      #   -> gateway Matrix adapter (plugins/platforms/matrix)
      # - "edge-tts": edge-tts SDK (7.2.7, pure python) of the free TTS provider
      #   by default. Without it, the tts tool fails with "No TTS provider
      #   available" (the nix venv contains no TTS engine).
      # - "stt-whisper": faster-whisper (local transcription, free, CPU) for
      #   incoming voice messages. Without it the gateway replies "voice message could not
      #   be transcribed automatically" and the use case "I speak into my
      #   earphones from Element" does not work.
      # - "anthropic": package of the native `anthropic` provider, the one for the lines of the
      #   model selector WITHOUT the [1m] suffix (claude-opus-5-5, claude-opus-5,
      #   claude-sonnet-5). Without it, a session opened on one of these lines
      #   dies with agent_init_failed ("The 'anthropic' package is required for the
      #   Anthropic provider"). The lines WITH [1m] go through the
      #   claude-subscription-directsdk provider (CLI `claude`) and do not need it.
      #   Auth of this native provider: no API key, agent/anthropic_credentials.py
      #   takes the subscription OAuth from ~/.claude/.credentials.json (refresh and
      #   rewrite handled by Hermes) or a Hermes grant
      #   (hermes auth add anthropic --type oauth).
      extraDependencyGroups = ["matrix" "edge-tts" "stt-whisper" "anthropic"];

      # claude-code CLI on the service PATH: required by the official
      # claude-subscription-directsdk plugin (provider on Claude Pro/Max subscription,
      # OAuth login via `claude`, no API key)
      extraPackages = [
        claudeCode
        # node/npm: required by the GitHub MCP (npx -y @modelcontextprotocol/server-github)
        pkgs.nodejs_22
        # binutils: provides `ld` and `objdump` on the PATH, on which the fallback of
        # ctypes.util.find_library("opus") for libopus depends (Discord voice). See the
        # "Opus" block below.
        pkgs.binutils
        # ffmpeg: required by Discord voice on BOTH sides (conversion of TTS to
        # PCM 48 kHz for output, and decoding on the receiving side). Without it in the
        # service PATH, `hermes doctor` reports "install out of sync" and
        # voice playback fails.
        pkgs.ffmpeg
      ];
      # settings.model = {
      #   base_url = "https://api.anthropic.com/v1";
      #   default = "anthropic/claude-sonnet-4";
      # };
      settings = {
        # --- Persistent memory limits ---
        # Memory (MEMORY.md, injected on EVERY turn) is capped by default
        # at 2200 chars (~800 tokens) and the user profile (USER.md) at 1375.
        # Values read from the code (tools/memory_tool.py): the keys read
        # are memory_char_limit / user_char_limit in the `memory` section.
        # Procedural knowledge stays in the skills (loaded on demand);
        # these limits only serve facts valid across any session.
        memory = {
          memory_char_limit = 6000; # ~2200 tokens, vs 2200 chars by default
          user_char_limit = 3000; # ~1100 tokens, vs 1375 by default
        };

        # --- hermes-tools MCP: the transport lives in the file, not in the option ---
        # The `services.hermes-agent.mcpServers.<name>` option is a typed submodule
        # that does NOT expose a `transport` key (only command/args/env/url/
        # headers/timeout/tools). But tower's mcp-host daemon only speaks SSE
        # (its Hermes runtime has no mcp.client.streamable_http): without this key,
        # a `url` entry is attempted as streamable HTTP and fails with 404.
        # `settings` is copied as-is into config.yaml, where the key is valid;
        # the merge at activation keeps the file's existing keys, so
        # this one survives even without being in the typed option.
        mcp_servers.hermes-tools.transport = "sse";

        # --- Fast sessions: cap the context replayed on each turn ---
        # Measurement of 25/11/2026: `threshold: 0.5` applies to the
        # declared `context_length` of the model, i.e. 0.5 x 1 048 576 = 524k
        # tokens. None of marc's chats reach it (110k to 205k observed), so
        # compression NEVER triggered and each turn re-paid for the whole
        # history (2.4 to 8.0 s per API call, 166 calls for a single
        # investigation turn).
        #   - `threshold_tokens` is a CAP on the computed threshold (the code
        #     takes the minimum of the two, with a hard floor at 64k). 150k keeps
        #     a comfortable margin above the observed sessions.
        #   - `proactive_prune_tokens` (0 = disabled upstream) prunes large
        #     tool results (> proactive_prune_min_result_chars = 8000
        #     chars) once the context is above the threshold: removes the
        #     "a 68 KB file read once, re-sent on every turn for
        #     ever" without an extra LLM call.
        compression = {
          threshold_tokens = 150000;
          proactive_prune_tokens = 60000;
        };

        # --- Kimi/Moonshot custom provider ---
        custom_providers = [
          {
            name = "kimi-k3-global";
            base_url = "https://api.moonshot.ai/v1";
            key_env = "KIMI_API_KEY"; # <- the env var that carries your key
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

          # --- Custom provider: llama.cpp + llama-swap of the laptop ---
          # The laptop (RTX 3060 6 GB) serves several GGUF on A SINGLE port
          # OpenAI-compatible, reached via the tailnet (100.64.0.4:8080). Local
          # server without a key: no key_env, Hermes substitutes "no-key-required".
          # qwen3.5-4b is the only comfortable model in Hermes (64k, 20-40
          # tok/s measured, correct tool calls); qwen3.5-2b is tiny
          # and fast; ornith-9b caps at 16k and ~5 tok/s (web interface
          # of llama-swap only). This entry must live HERE: an entry
          # added hot into config.yaml is overwritten at activation (the
          # Nix merge replaces lists, it does not merge them).
          {
            name = "laptop-llama";
            base_url = "http://100.64.0.4:8080/v1";
            api_mode = "chat_completions";
            model = "qwen3.5-4b";
            models = {
              "qwen3.5-4b".context_length = 65536;
              "qwen3.5-2b".context_length = 65536;
              "ornith-9b".context_length = 16384;
              # NO qwen3-8b-abl-32k here, and not by mistake: Qwen3-8B has
              # n_ctx_train = 40960, so it can NEVER reach the minimum
              # of 64 000 tokens required by Hermes (verified on 15/11:
              # "ValueError: Model qwen3-8b-abl-32k has a context window of
              # 32,768 tokens, which is below the minimum 64,000 required by
              # Hermes Agent"). Declaring it at 32k fails the turn;
              # declaring it at 64k would make Hermes lie about a window that the
              # server truncates. It stays in llama-swap.yaml for the
              # web interface of llama-swap, not for Hermes.
            };
          }

          # --- Custom provider: Qwen3.5 4B abliterated on the laptop ---
          # Same endpoint as laptop-llama (100.64.0.4:8080), NOT a second
          # server: the former user unit llama-abl.service (port 8083) held
          # 4.9 GB of the 6 GB of VRAM permanently. llama-swap could not
          # unload it, so any other model failed at load with
          # cudaMalloc OOM and Hermes received "upstream command exited
          # prematurely" (HTTP 500). The unit is removed, the model lives in
          # llama-swap.yaml (qwen3.5-4b-abl, 96k, KV q4_0, all in VRAM).
          # Measurements of 15/11 on this endpoint: 676 tok/s of prefill and 16 tok/s
          # of decode on a 36 844 token prompt, 4.6 GB of VRAM.
          # 96k and not 128k: at 131k the KV no longer fits with the compute
          # buffers and -fit offloads layers to the CPU (decode drops to
          # 3 tok/s). The largest entry observed on the Hermes side is 49k.
          {
            name = "laptop-abl";
            base_url = "http://100.64.0.4:8080/v1";
            api_mode = "chat_completions";
            model = "qwen3.5-4b-abl";
            models = {
              "qwen3.5-4b-abl".context_length = 98304;
            };
          }

          # (DeepSeek direct: NO custom provider here, the INTEGRATED
          # `deepseek` provider covers the case. It carries the upstream ProviderProfile which
          # emits `extra_body.thinking` explicitly and maps the effort to
          # `reasoning_effort`: without it the V4 API leaves thinking ON by default
          # and requires sending `reasoning_content` back on the next turn (HTTP 400
          # after the first tool call). A custom provider does not receive this
          # profile, it only served to declare the 1 M / vision metadata.)
        ];

        # --- Default model: DeepSeek v4.1 Flash, served DIRECT ---
        # marc's policy of 11/11/2026: the direct DeepSeek account replaces
        # OpenRouter for the default model (top-up balance tracked on
        # usage.marcpartensky.com, off-peak twice as cheap).
        # Provider = the INTEGRATED `deepseek` slug (not a custom one): a single
        # DeepSeek entry in the picker, and the upstream ProviderProfile handles
        # the thinking contract of the V4 API. The custom `deepseek-direct` slug
        # duplicated the same pair of models.
        # The fallback chain just below stays OpenRouter (pinned to
        # endpoints without training, see provider_routing) then the
        # Nemotron: a zero DeepSeek balance does not cut off the agent.
        # 25/11/2026: the switch of the default to the aggregator made last
        # night was cancelled (marc: "the default is now
        # openrouter, fix it"). The privacy hardening of the day before is
        # kept, but it applies to the OpenRouter ROUTE (fallback), not to the
        # default: changing the default is a cost decision, separate.
        model = {
          provider = "deepseek";
          default = "deepseek-flash";
          # base_url declared EXPLICITLY: the file in place kept
          # https://openrouter.ai/api/v1 from the previous default, and a stale
          # base_url with a DeepSeek model name would make a silent 400
          # (switch to the fallback chain without it being visible).
          base_url = "https://api.deepseek.com/v1";
        };

        # --- Fallback chain: OpenRouter (hardened route) then Nemotron ---
        # The first fallback is the same model served by OpenRouter, pinned
        # by `provider_routing.models` to the US endpoints without training
        # (DeepInfra, River, CoreWeave...). It is this route that carries the
        # privacy hardening of 24/11; it is the fallback, not the default.
        # The `:free` Nemotron was replaced by its paid endpoint: the
        # free endpoints are in the "retention + training" tier and the
        # `data_collection = "deny"` filter rejects them (verified: HTTP 404
        # "No endpoints found matching your data policy (Free model training)"),
        # which made it dead code.
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
            model = "nvidia/nemotron-3-ultra-550b-a55b";
            context_length = 262144;
          }
        ];

        # --- Privacy: never route to a provider that stores prompts for training ---
        # `data_collection = "deny"` drops OpenRouter's retention/training tier
        # (verified against the live API: with this filter the `:free` Nemotron
        # endpoint answers 404 "No endpoints found matching your data policy",
        # while the primary and the paid Nemotron stay routable). `ignore` drops
        # providers whose headquarters or datacenters published on
        # /api/v1/providers are in the PRC, so prompt content does not land on
        # Chinese infrastructure. Hermes forwards both fields on every
        # OpenRouter request (provider_routing: sort/only/ignore/order/
        # require_parameters/data_collection). It does NOT forward `zdr`, so
        # Zero Data Retention stays a dashboard setting:
        # https://openrouter.ai/settings/privacy
        provider_routing = {
          data_collection = "deny";
          ignore = [
            "deepseek" # CN
            "tencent" # CN
            "baidu" # CN
            "nex-agi" # CN
            "xiaomi" # CN
            "streamlake" # CN
            "stepfun" # CN
            "alibaba" # SG, datacenters SG + CN
            "siliconflow" # SG
          ];
          # --- Per-model pin for the OpenRouter route (first fallback) ---
          # 98.18% of input tokens over the last 30 days were cache reads
          # (6.674e9 hit vs 1.239e8 miss), so the cache-read price dominates and
          # a `sort = "price"` pick is a trap: Wafer's $0.051/M input looks
          # cheapest, but its $0.018/M cache read is 6x DeepSeek's and 5x
          # DeepInfra's. Repricing the same 30-day mix (2026-11-24 prices, all
          # `training = false` + ZDR tier endpoints):
          #   DeepInfra $51.17 | River $52.12 | CoreWeave $55.55 | Relace $57.01
          #   Cohere $73.38 | Crusoe $88.23 | InferenceNet $92.70
          #   DeepSeek direct off-peak $65.15 | peak $130.30 | recorded spend $71.23
          #   Wafer $151.55 | Cloudflare $252.45
          models = {
            "deepseek/deepseek-v4.1-flash" = {
              only = [
                "deepinfra" # US, fp8 flex
                "river" # US HQ, EU datacenters (FI/IS)
                "coreweave" # US, fp8
                "relace" # fp4
                "cohere" # US, fp8
                "crusoe" # US, fp8
                "inference-net" # US, fp8
              ];
              order = [
                "deepinfra"
                "river"
                "coreweave"
                "relace"
                "cohere"
                "crusoe"
                "inference-net"
              ];
            };
          };
        };

        agent = {
          reasoning_effort = "max";
          # marc's policy of 25/09/2026: the level follows the model.
          # DeepSeek Flash -> high; Opus 5 -> max; Sonnet 5 -> high.
          # Two keys per family: full form (deepseek/... , default model)
          # and bare form ([1m] of the rooms, fallback route); the resolution is
          # tolerant of naming variants.
          reasoning_overrides = {
            "deepseek/deepseek-v4.1-flash" = "high";
            "deepseek-v4.1-flash" = "high";
            # Same levels for the names served by the direct DeepSeek API
            # (INTEGRATED `deepseek` provider). V4-Pro is the big model:
            # max, like Opus 5.
            "deepseek-flash" = "high";
            "deepseek-v4-pro" = "max";
            "nvidia/nemotron-3-ultra-550b-a55b" = "max";
            "nemotron-3-ultra" = "max";
            "claude-opus-5-5[1m]" = "max";
            "claude-opus-5-5" = "max";
            "claude-opus-5[1m]" = "max";
            "claude-opus-5" = "max";
            "claude-sonnet-5[1m]" = "high";
            "claude-sonnet-5" = "high";
          };
        };

        # --- Estimated cost in the CLI/TUI status bar ---
        # interface = "tui": the classic REPL writes NO terminal title
        # (no terminal_title module in the installed version), whereas the TUI
        # publishes its title in OSC 0/1/2: "<state> <session> - <model> - <cwd>".
        # It is this title that herdr reads for the state (blocked/working/done) AND to
        # display the model of each pane in its sidebar (modules/nixos/herdr).
        # Without this setting, the hermes panes do not expose their model to herdr.
        display = {
          show_cost = true;
          interface = "tui";
          # "Claude Code" theme (neutral grays + lavender accent), requested by
          # marc on 21/11/2026 to remove the lavender interface from the desktop.
          # The palette YAML lives in this repo and is copied at activation
          # (see tmpfiles/activation script): it also carries the customCSS of the
          # desktop surfaces (composer/bubbles/rounded cards).
          skin = "claude-code";
        };

        # Web DASHBOARD theme (dash.marcpartensky.com): same palette as the
        # skin above. The dashboard does NOT use display.skin (that is the CLI/TUI
        # and the desktop): it reads `dashboard.theme`, which must name a user
        # theme discovered in $HERMES_HOME/dashboard-themes/*.yaml.
        # This YAML is set declaratively by tmpfiles (see below), hence the
        # identical name on both sides: rename it in both places.
        dashboard = {
          theme = "catppuccin-mocha-lavender";

          # --- Zitadel SSO: a SECOND door, backed by a role -----------
          # The `basic` password stays in place for marc (no change
          # for him); this provider adds a "Self-Hosted OIDC" button to the
          # login page, for people who do not have the shared
          # password. The entry right is a ZITADEL ROLE, not a list
          # of emails: the "Hermes Webapp" app (client_id below, type
          # User Agent = public PKCE without secret, EXACT redirect
          # https://hermes.marcpartensky.com/auth/callback) lives in the Zitadel
          # project "Hermes" (400179685910118700) which carries
          # project_role_check=true: Zitadel refuses to authenticate an account
          # that has NO role on this project, so only a holder of the
          # `hermes` role gets an id_token. Removing the role is enough to cut
          # access, without a rebuild.
          # `idTokenUserinfoAssertion` is ENABLED on the app on the Zitadel side: this
          # provider reads ONLY the id_token (never /userinfo), without it email and
          # name are absent and the session is anonymous.
          # Read at gateway STARTUP: a switch sets the config, the
          # SSO button appears at the next start of hermes-agent.
          oauth.self_hosted = {
            issuer = "https://auth.marcpartensky.com";
            client_id = "400179699633946924";
            # Zitadel scopes, all measured on the instance (18/11/2026):
            #   openid profile email                        -> basic identity
            #   urn:zitadel:iam:org:id:<org>                -> scopes the login to the default org
            #                                                  and sets
            #                                                  `urn:zitadel:iam:org:id`
            #   urn:zitadel:iam:org:roles:id:<org>          -> returns only the
            #                                                  roles of that org
            #   urn:zitadel:iam:user:resourceowner          -> id/name/domain of
            #                                                  the account's org in
            #                                                  the token
            # The roles themselves come from `idTokenRoleAssertion` (set on
            # the app): claim `urn:zitadel:iam:org:project:roles`.
            scopes = "openid profile email urn:zitadel:iam:org:id:314403750724829190 urn:zitadel:iam:org:roles:id:314403750724829190 urn:zitadel:iam:user:resourceowner";
          };
        };

        # --- Command approvals: no human validation anymore ---
        # marc's policy of 13/10/2026: the shell no longer asks anything before
        # executing a command. "off" is the third bypass of the gate
        # (tools/approval.py, is_approval_bypass_active_for_session: yolo OR
        # session /yolo OR mode == off) and it is tested BEFORE the
        # cron / single_query / unattended branches, so it also cuts the default
        # refusals in headless context (cron_mode etc. become moot).
        # The web tools (web_search / web_extract) already went through no
        # prompt: this key only concerns dangerous shell
        # commands (rm -r, chmod 777, bash -c, curl | sh, systemctl...).
        # Still active despite "off": the hardline blocklist code-shipped
        # (tools/approval.py::UNRECOVERABLE_BLOCKLIST) and the
        # approvals.deny rules (empty here) - no override possible.
        approvals = {
          mode = "off";
        };

        # --- "shared metrics" telemetry: explicit "No thanks" answer ---
        # Marc does not share stats (23/10/2026). The offer (Desktop banner,
        # dashboard banner) is considered answered as soon as ONE of the two keys
        # is written EXPLICITLY in config.yaml - the default (all
        # disabled) is NOT an answer, so the question comes back at each
        # session as long as these keys are absent.
        #   enabled=false + send=false  -> "No thanks" answer
        #   offer_version=2             -> avoids the single "re-ask" planned
        #     for "off" answers prior to the type-ahead fix
        #     (consent_state: an off answer without offer_version=2 is
        #     re-asked once). With these three keys, decided=true everywhere.
        # No data is collected or sent with these values; to
        # change your mind: edit this block + rebuild (nix-managed install).
        telemetry = {
          shared_metrics = {
            enabled = false;
            send = false;
            offer_version = 2;
          };
        };

        # --- herdr plugin: integrates hermes into herdr, declaratively ---
        # `extraPlugins` symlinks the package into /var/lib/hermes/.hermes/plugins/
        # (under the name nix-managed-<name>); the plugin code is vendored in
        # services/hermes/plugins/herdr-agent-state (a copy of what
        # `herdr integration install hermes` produces), so no more imperative install.
        # This plugin reports the SESSION ID to herdr (herdr pane
        # report-agent-session), which lets herdr relaunch the pane in its
        # conversation (`hermes --resume <id>`, option [session]
        # resume_agents_on_restore).
        # LIMIT: the plugin exits immediately if HERDR_ENV != 1 or without
        # HERDR_PANE_ID, and it talks to MARC's herdr socket
        # (~/.config/herdr/herdr.sock): it can therefore only work if hermes
        # runs in the pane with the herdr env and under the same user as the
        # herdr server. The usual launch (`sudo su -l hermes hermes chat`)
        # clears this env -> plugin inert but with no side effect.
        # `matrix-loop-emoji`: 🔄 emoji at the end of each Matrix message, and a
        # 🔄 reaction from an authorized user on a bot message renews
        # the session (path of /new, without confirmation). Code vendored in
        # services/hermes/plugins/matrix-loop-emoji and placed by hermesHomeFiles.
        # `turn-scoped-desktop-lease` : a Desktop chat's active-session lease is
        # released at turn end instead of being held for the whole life of the
        # tab, so a second Hermes window can take the chat over instead of
        # "This chat is open in another Hermes window/terminal" until the first
        # window idles out. Code vendored in
        # services/hermes/plugins/turn-scoped-desktop-lease.
        plugins = {
          enabled = [ "herdr-agent-state" "matrix-loop-emoji" "turn-scoped-desktop-lease" ];
        };

        # --- TTS: Edge TTS (free, without API key) ---
        # French voice by default (Hermes replies in French). The SDK is provided
        # by extraDependencyGroups = "edge-tts" above; without this group the
        # tts tool fails. Other fr voices: fr-FR-HenriNeural (male),
        # fr-FR-VivienneMultilingualNeural, fr-FR-RemyMultilingualNeural,
        # fr-CA-SylvieNeural. Full list: `edge-tts --list-voices`.
        # Automatic reading of replies: voice.auto_tts (default false;
        # on demand via /voice tts in the CLI).
        tts = {
          provider = "edge";
          edge = {
            voice = "fr-FR-DeniseNeural";
          };
        };

        # --- STT: local faster-whisper (free, CPU, without API key) ---
        # Automatically transcribes incoming voice messages (Matrix/Element, etc.):
        # the gateway transcribes any voice message when stt.enabled is true.
        # The engine comes from the "stt-whisper" group above.
        # language = "" is IMPORTANT: the default value is "en", which forces
        # Whisper to decode French as English. Empty = automatic
        # detection (measured: fr detected at p=0.99 on a short voice message).
        # "base" model (140 MB, ~5 s for 3 s of audio, CPU); "small" or "medium"
        # if the accuracy is not enough with an earphone mic in a noisy
        # environment. provider not declared = auto scale (local first).
        stt = {
          enabled = true;
          language = "";
          local = {
            model = "base";
          };
        };

        auxiliary = {
          # vision: stays on kimi explicitly (do not tap into the Claude Pro
          # quota for image descriptions)
          vision = {
            provider = "custom:kimi-k3-global";
            model = "kimi-k3";
            extra_body = {
              reasoning_effort = "max";
            };
          };

          # title_generation: pin on the cloud model, NEVER the local model.
          # Without a pin, the aux follows the session model. A session opened on
          # the laptop (--parallel 1, 2 to 16 tok/s) therefore saw its title
          # generation queue behind the main turn and time out at 30 s
          # ("Auxiliary title_generation: request to http://100.64.0.4:8080/v1/
          # timed out after 30.0s"), then fail for lack of fallback.
          # 25/11/2026: pin put back on the direct route, like the default. A
          # session title is generated FROM the conversation, so it
          # must land on the same account as the default, not on the aggregator.
          title_generation = {
            provider = "deepseek";
            model = "deepseek-flash";
          };
        };

        # --- Per-Matrix-room model: channel_overrides policy ---
        # Most rooms stay on the default (DeepSeek v4.1 Flash,
        # direct `deepseek` account; the fallbacks go through OpenRouter).
        # The rooms below run on the Claude subscription (DirectSDK):
        # Opus 5 (O5), or Sonnet 5 at high effort for Zoe (S5 high, 1M).
        # Read by the gateway at startup (a restart is required after the switch).
        platforms = {
          matrix = {
            channel_overrides = {
              "!zQZcqfoWStODYAuIUE:matrix.marcpartensky.com" = {
                provider = "claude-subscription-directsdk-experimental";
                model = "claude-opus-5[1m]";
              };
              # Nino: Opus 5.5 (native route `claude-opus-5-5`, dashes; the form
              # `claude-opus-5.5` is rejected by the CLI). [1m] variant = 1M of
              # context; max effort via reasoning_overrides.
              # Nino: DeepSeek v4.1 Flash (OpenRouter), 1st fallback by default.
              "!zOyDctBWcuFCJKJINI:matrix.marcpartensky.com" = {
                provider = "openrouter";
                model = "deepseek/deepseek-v4.1-flash";
              };
              # Zoe: DeepSeek v4.1 Flash (OpenRouter), 1st fallback by default.
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

      # --- herdr plugin: integrates hermes into herdr, declaratively ---
      # SERVICE option (not in settings: an extraPlugins put in settings
      # just ends up as an inert key of config.yaml, and no symlink is created).
      # `extraPlugins` symlinks the package into /var/lib/hermes/.hermes/plugins/
      # under the name nix-managed-<name>; the plugin code is vendored in
      # services/hermes/plugins/herdr-agent-state (a copy of what
      # `herdr integration install hermes` produces), so no more imperative install.
      # This plugin reports the SESSION ID to herdr (herdr pane
      # report-agent-session), which lets herdr relaunch the pane in its
      # conversation (`hermes --resume <id>`, option [session]
      # resume_agents_on_restore).
      # LIMIT: the plugin exits immediately if HERDR_ENV != 1 or without
      # HERDR_PANE_ID, and it talks to MARC's herdr socket
      # (~/.config/herdr/herdr.sock, 0600, directory 0700): it can therefore
      # only work if hermes runs in the pane with the herdr env AND under
      # the marc user. The usual launch (`sudo su -l hermes hermes
      # chat`) clears this env -> plugin inert but with no side effect.
      extraPlugins = [
        (pkgs.runCommandLocal "herdr-agent-state" {} ''
          mkdir -p $out
          cp ${./plugins/herdr-agent-state/plugin.yaml} $out/plugin.yaml
          cp ${./plugins/herdr-agent-state/__init__.py} $out/__init__.py
        '')

        # --- Automatic join of the Discord voice channel ---
        # Hermes only joins voice on `/voice join`; this plugin adds a
        # native discord.py handler on the Discord adapter (ctx.
        # register_platform_handler): an authorized member joins a voice channel
        # -> the bot connects to it, and leaves when nobody is there anymore. It
        # wires `adapter.join_voice_channel(text_channel_id=...)`, essential
        # because without a linked text channel the transcription is discarded.
        (pkgs.runCommandLocal "discord-auto-join" {} ''
          mkdir -p $out
          cp ${./plugins/discord-auto-join/plugin.yaml} $out/plugin.yaml
          cp ${./plugins/discord-auto-join/__init__.py} $out/__init__.py
        '')
      ];

      # --- Gateway hook: Matrix -> Gotify bridge ---
      # Vendored here, installed into $HERMES_HOME/hooks/gotify-notify (extension
      # point "trusted by placement": the gateway loads at startup any
      # directory containing HOOK.yaml + handler.py, so a switch is enough to
      # enable it). The handler reads the Gotify application token provisioned by
      # services/gotify-matrix and pushes the replies published in the bridge
      # room. Details and filters: services/hermes/hooks/gotify-notify/handler.py.
      hermesHomeFiles = {
        "hooks/gotify-notify/HOOK.yaml" = ./hooks/gotify-notify/HOOK.yaml;
        "hooks/gotify-notify/handler.py" = ./hooks/gotify-notify/handler.py;

        # matrix-loop-emoji plugin: placed directly in $HERMES_HOME/plugins/
        # under its original name (no nix-managed- prefix), so that it is
        # loaded as a "user" plugin and not duplicated via extraPlugins.
        "plugins/matrix-loop-emoji/plugin.yaml" = ./plugins/matrix-loop-emoji/plugin.yaml;
        "plugins/matrix-loop-emoji/__init__.py" = ./plugins/matrix-loop-emoji/__init__.py;

        # Plugin turn-scoped-desktop-lease : same drop-in, see the `plugins`
        # block above for what it changes.
        "plugins/turn-scoped-desktop-lease/plugin.yaml" = ./plugins/turn-scoped-desktop-lease/plugin.yaml;
        "plugins/turn-scoped-desktop-lease/__init__.py" = ./plugins/turn-scoped-desktop-lease/__init__.py;

        # OpenRouter Zero Data Retention. Hermes forwards only
        # sort/only/ignore/order/require_parameters/data_collection from
        # `provider_routing` (agent/chat_completion_helpers.py), so OpenRouter's
        # per-request `provider.zdr` cannot be set from config even though the
        # API accepts it. This model-provider plugin SHADOWS the bundled
        # `openrouter` profile (a $HERMES_HOME plugin wins on a name collision,
        # providers/__init__.py::register_provider) and adds `zdr: true` to the
        # provider preferences of every OpenRouter request, so OpenRouter only
        # routes to endpoints with a Zero Data Retention policy. It lives under
        # plugins/model-providers/ (NOT plugins/) because that is the directory
        # the provider registry scans, and it needs no `plugins.enabled` entry:
        # every directory there is imported at discovery.
        "plugins/model-providers/openrouter-zdr/plugin.yaml" = ./plugins/openrouter-zdr/plugin.yaml;
        "plugins/model-providers/openrouter-zdr/__init__.py" = ./plugins/openrouter-zdr/__init__.py;
      };
    };

    # --- GitHub MCP: official server (@modelcontextprotocol/server-github) ---
    # Note: the package is deprecated (2025.4.8) but still functional.
    # Replace the placeholder with the real GitHub token (fine-grained PAT).
    services.hermes-agent.mcpServers.github = {
      command = "npx";
      args = [ "-y" "@modelcontextprotocol/server-github" ];
      env = {
        GITHUB_PERSONAL_ACCESS_TOKEN = "ghp_PLACEHOLDER_REPLACE_WITH_REAL_TOKEN";
      };
      timeout = 60;
    };

    # --- Gitea MCP: official server (gitea.com/gitea/gitea-mcp) ---
    # Requires a Gitea PAT (Settings -> Applications -> Generate Token)
    # scopes: repo, admin:org, admin:user, notification, user, write:package, read:package
    services.hermes-agent.mcpServers.gitea = lib.mkIf config.services.hermes.enableGiteaMcp {
      command = "gitea-mcp";
      args = [ "-t" "stdio" ];
      env = {
        GITEA_HOST = "https://git.marcpartensky.com";
        GITEA_ACCESS_TOKEN_FILE = config.sops.secrets."gitea-mcp/pat".path;
      };
      timeout = 60;
    };

    # --- Hinge MCP: driving the app on marc's phone -----------------
    # The phone runs android-remote-control-mcp on its 127.0.0.1:8080.
    # It is reached through the phone's sshd (maintained by phone-up/watchdog on the phone side).
    # The forward is a service here, never a session `ssh -N -L`: it survives
    # disconnections and restarts on its own. On the client side, hinge_mcp.py speaks stdio.
    systemd.services.phone-mcp-tunnel = {
      description = "Loopback forward to the phone MCP (ssh -L 18080)";
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

    # --- iprep MCP: aggregated IP reputation score ---------------------------
    # Hand-written stdio server (python stdlib, no dependency) that
    # queries public keyless sources (Scamalytics, AlienVault OTX,
    # StopForumSpam, GreyNoise community, Project HoneyPot, DNSBL) and returns
    # a normalized risk 0-100 per source + the average. AbuseIPDB and
    # IPQualityScore are added if ABUSEIPDB_API_KEY / IPQS_API_KEY are
    # provided in the environment (optional, without a key they are ignored).
    services.hermes-agent.mcpServers.iprep = {
      command = "${pkgs.python3}/bin/python3";
      args = [ "/var/lib/hermes/workspace/iprep-mcp/server.py" ];
      # The MCP reads four sources in the real Chrome on the Mac: it needs
      # node to drive the CDP and the loopback tunnel below.
      env.IPREP_NODE = "${pkgs.nodejs}/bin/node";
      timeout = 300;
    };

    # Loopback tunnel to the CDP of the Mac's "agent" Chrome (9222 on the Mac side,
    # 19222 on the tower side). The iprep MCP uses it for the four sources that
    # Cloudflare closes to curl and headless Chromium: AbuseIPDB,
    # IPQualityScore, Cisco Talos, check.spamhaus.org. Same pattern as
    # phone-mcp-tunnel: a service, not a session `ssh -N -L`, so that it
    # survives disconnections. Host `mac` (autossh reverse tunnel of the Mac), so
    # valid also outside tower's LAN.
    systemd.services.mac-cdp-tunnel = {
      description = "Loopback tunnel to the CDP of the Mac's agent Chrome";
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

    # --- chrome-mac MCP: Mac's Chrome MCP Server extension -------------------
    # Replaces firefox-mac (Marionette) since 15/11/2026. Measurement on tower:
    # a Firefox launched with --marionette advertises navigator.webdriver=true even
    # without an attached client, whereas a Chromium reached by --remote-debugging-port
    # alone stays at false. The extension, loaded in the Mac's Chrome, adds
    # in addition the browser APIs (tabs, bookmarks, history, downloads) and
    # accepts several simultaneous clients (Marionette only accepts one).
    # On the Mac side (imperative, outside the flake, like geckodriver):
    #   npm i -g mcp-chrome-bridge && mcp-chrome-bridge register
    # then load ~/apps/chrome-mcp-server by hand in chrome://extensions
    # (Chrome 157 refuses --load-extension). The bridge listens on 127.0.0.1:12306/mcp
    # hence the loopback tunnel below. Threat model: the bridge has no
    # authentication, it must stay only on the Mac's loopback.
    systemd.services.mac-mcp-chrome-tunnel = {
      description = "Loopback tunnel to the MCP of the Mac's Chrome extension";
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
          + "-o BatchMode=yes -L 127.0.0.1:19236:127.0.0.1:12306 mac";
      };
    };

    services.hermes-agent.mcpServers.chrome-mac = {
      url = "http://127.0.0.1:19236/mcp";
      timeout = 180;
    };

    # --- phonerep MCP: aggregated PHONE NUMBER reputation score ------
    # Same convention as iprep (risk 0-100 per source + average, 0 = clean).
    # Keyless sources: veriastra (spam score + FTC complaints, validity and
    # carrier), spamcalls, RoboKiller, shouldianswer, Nomorobo,
    # 800notes/whocallsme. phonenumbers (nix package) gives E.164
    # normalization and the line type offline. VERIASTRA_API_KEY and IPQS_API_KEY
    # are optional: without a key these sources are ignored and reported.
    # tellows and the free IPQS page still have to be read in a real browser.
    services.hermes-agent.mcpServers.phonerep = {
      command = "${pkgs.python3.withPackages (p: [ p.phonenumbers ])}/bin/python3";
      args = [ "/var/lib/hermes/workspace/phonerep-mcp/server.py" ];
      timeout = 180;
    };

    # --- Pangolin MCP: self-hosted integration API ---
    # The v1 API (Bearer key, "hermes" key of the dashboard's apiKeys table) is
    # enabled by the enable_integration_api flag of services/pangolin and
    # answers on api.marcpartensky.com/v1 (dedicated traefik router); NOT on
    # pangolin.vps.marcpartensky.com which only serves the dashboard. The script
    # (services/hermes/pangolin-mcp.py) re-reads the key at each call; a
    # already-running process keeps its old PANGOLIN_BASE_URL until
    # hermes restarts.

    # --- voice MCP (TTS): HTTP server on the LAPTOP, reached via the tailnet ---
    # The engines (Phonon, Kokoro on CPU; OmniVoice, Ming, Chatterbox, Breeze
    # on GPU), the weights and the RTX 3060 are on the laptop: any voice
    # generation stays there, whichever machine drives the agent. The
    # server lives in services/tts-mcp (laptop) and keeps the models warm;
    # large timeout because a GPU engine loads its model before speaking.
    # Address: laptop's tailscale (100.64.0.4), port open on
    # tailscale0 only.
    services.hermes-agent.mcpServers.tts = {
      url = "http://100.64.0.4:8092/mcp";
      timeout = 900;
    };

    # --- Vaultwarden MCP: temporarily disabled (sops manifest block) ---
    # services.hermes-agent.mcpServers.vaultwarden = {
    #   command = "vaultwarden-mcp";

    # --- node/npm required for the GitHub server (npx) ---
    # (added in extraPackages above: the option accepts only one definition)

    # --- ollama: local embeddings for mem0 ---
    # nomic-embed-text = 768 dims, supported by the mem0 plugin. CPU is enough.
    services.ollama = {
      enable = true;
      loadModels = ["nomic-embed-text"];
    };

    # claude also available for marc and hermes CLI sessions
    # (the SYSTEM python3 is already added outside the block above, see at the top of
    # `config`: required by the SSH probe of Hermes Desktop)

    # Agent secrets: A SINGLE sops file (secrets/hermes-agent.yml),
    # recipients = tower + laptop + VPS + Mac. It replaces the copies
    # scattered around (hermes_env was encrypted twice, in tower.yml AND
    # anywhere.yml): adding a fallback host now only requires a
    # `sops updatekeys secrets/hermes-agent.yml` instead of one per file.
    # What remains outside this file is deliberately single-host: gemini and
    # the Matrix/Discord token (single bot, two gateways with the same token would
    # fight over the connection).
    sops.secrets."hermes_env" = {
      sopsFile = ../../secrets/hermes-agent.yml;
    };

    # Key of the direct DeepSeek account, in clear for the agent: its content is a
    # dotenv ("DEEPSEEK_API_KEY=...") added to the unit's environmentFiles,
    # so read by the INTEGRATED deepseek provider (model.provider above).
    # Same file as
    # the balance shown by the usage dashboard (secrets/deepseek.yml).
    sops.secrets."hermes_deepseek_env" = {
      key = "hermes_deepseek_env";
      sopsFile = ../../secrets/hermes-agent.yml;
    };

    # Key of the Meta Model API account (INTEGRATED meta-ai provider, env MODEL_API_KEY).
    # dotenv content, like the DeepSeek key. Standard mode only on the Meta
    # side (no Contributor for Ember): the content is not used to
    # train. Rotation / setting the value: sops set, never the file by
    # hand.
    sops.secrets."hermes_meta_env" = {
      key = "hermes_meta_env";
      sopsFile = ../../secrets/hermes-agent.yml;
    };

    # Gemini key (Google AI Studio) for the INTEGRATED gemini provider (env
    # GOOGLE_API_KEY). dotenv content, same mechanism as deepseek/meta. No
    # plugin or CLI required: the provider speaks HTTPS to
    # generativelanguage.googleapis.com. Free tier = prompts used to
    # improve Google products; take the paid tier to avoid it.
    sops.secrets."hermes_gemini_env" = lib.mkIf config.services.hermes.enableGeminiToken {
      key = "hermes_gemini_env";
      sopsFile = ../../secrets/hermes-gemini.yml;
    };

    # Key of the API Server listener of the default profile ("hermes_api_server_env" key
    # of the sops file, value = dotenv content "API_SERVER_KEY=..."). Same value
    # as HERMES_BRIDGE_API_KEY on the services/discord-bot side, which sends it as Bearer:
    # the Discord bridge and the API server therefore share THE SAME key, encrypted
    # once in secrets/discord-hermes-bridge.yml.
    sops.secrets."hermes_api_server_env" = {
      # Lives in hermes-agent.yml so that the fallback laptop can
      # decrypt it (secrets/discord-hermes-bridge.yml only has tower's key).
      # SAME VALUE as HERMES_BRIDGE_API_KEY of services/discord-bot, which still reads it
      # from its own file: rotation = rewrite both keys in
      # the same step (see the header of both files).
      key = "hermes_api_server_env";
      sopsFile = ../../secrets/hermes-agent.yml;
    };

    # The secret above is a BARE key: rendered into .env by concatenation, it
    # would have no variable name. The template below turns it into a real
    # dotenv (API_SERVER_KEY=...), consumed by the hermes-agent unit.
    sops.templates."hermes-api-server.env".content = ''
      API_SERVER_KEY=${config.sops.placeholder."hermes_api_server_env"}
    '';

    # API key of the Pangolin MCP (root key "pangolin_api_key" of
    # secrets/common.yml, value = "hermes" key created in the dashboard).
    # owner hermes + 0400: the MCP is an agent process and re-reads this
    # file itself at each HTTP call. The former declaration pointed to
    # a non-existent nested key pangolin.api_key ("the key 'pangolin'
    # cannot be found" made any switch fail: left out of service
    # until now).
    sops.secrets."pangolin_api_key" = lib.mkIf config.services.hermes.enableAgent {
      sopsFile = ../../secrets/hermes-agent.yml;
      owner = "hermes";
      mode = "0400";
    };

    # Master password of the agent's Vaultwarden technical account
    # (hermes@marcpartensky.com), read by ~/.hermes/scripts/vault-get.sh.
    # It lived in services/vaultwarden/default.nix as long as this module was
    # imported by services/default.nix (so tower AND the laptop). Since
    # 14/11/2026 the Vaultwarden vault only runs on the VPS (profile
    # anywhere, single source of truth): the module is no longer imported here, but
    # the agent still needs the secret on tower to open its vault
    # remotely. File encrypted to tower's only age key.
    sops.secrets."vaultwarden/agent_password" = lib.mkIf config.services.hermes.enableAgent {
      key = "vaultwarden_agent_password";
      sopsFile = ../../secrets/hermes-agent.yml;
      owner = "hermes";
      group = "hermes";
      mode = "0400";
    };

    # Matrix token of the bot (@hermes) - "hermes_matrix_env" key of the sops file,
    # value = dotenv content (MATRIX_ACCESS_TOKEN=...) merged into .env.
    # Declared only where the option is active: the recipients of the file
    # do not include anywhere/laptop, declaring the secret there would fail
    # the activation (setupSecrets "0 successful groups required").
    sops.secrets."hermes_matrix_env" = lib.mkIf config.services.hermes.enableMatrixToken {
      sopsFile = ../../secrets/hermes-matrix.yml;
    };

    # Token of the dedicated Discord bot (voice + text) - "hermes_discord_env" key of
    # the sops file, value = dotenv content (DISCORD_BOT_TOKEN=...) merged
    # into .env. Declared only where the option is active, same reason as
    # for the Matrix token.
    sops.secrets."hermes_discord_env" = lib.mkIf config.services.hermes.enableDiscordToken {
      sopsFile = ../../secrets/hermes-discord.yml;
    };

    # --- Direct SSH access from hermes (tower) to the other hosts that import
    # this module (laptop, anywhere): defined at the top of `config` (user
    # hermes + key + sudo), common to all hosts.
    security.sudo.extraRules = [
      # marc: direct access kept (he owns the machine).
      {
        users = ["marc"];
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nixos-rebuild/bin/nixos-rebuild";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/nixos-rebuild-gated";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nixos-rebuild-gated/bin/nixos-rebuild-gated";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # --- The sudo rule above was INOPERATIVE from the hermes units ---
    # The hermes-agent module sets NoNewPrivileges=true in the serviceConfig
    # common to the gateway (hermes-agent.service) and to the backend (hermes-backend.
    # service). Under this flag the kernel IGNORES the setuid bit: sudo flatly refuses
    # ("the \"no new privileges\" flag is set"), su fails at setuid(), and the
    # flag is inherited by all children. Consequence: a session opened
    # from Matrix or from the web terminal could NOT launch the
    # nixos-rebuild that the NOPASSWD rule nevertheless grants it.
    #
    # So we disable it on both units. It does not give a root shell:
    # sudo stays bounded to the command list above.
    systemd.services.hermes-agent.serviceConfig.NoNewPrivileges = lib.mkForce false;
    systemd.services.hermes-backend.serviceConfig.NoNewPrivileges = lib.mkForce false;

    # --- The gateway must never be killed or starved ---
    # Without this block, hermes-agent lives in system.slice at the default weight
    # (100), on par with a nix build, without memory protection.
    #
    #  - hermes.slice CPUWeight=2000: under contention it goes before all the
    #    rest of system.slice (weight 100), i.e. 20x the default priority.
    #    A WEIGHT, not a quota: on a free machine it takes all the CPU, and nothing
    #    ever throttles it. (10000 gave ~91 % of the CPU under contention and
    #    dropped builds to ~0.2 %: too brutal, 2000 is more than enough.)
    #  - MemoryMin/MemoryLow: cgroup v2 floor, its memory is no longer
    #    reclaimable by another cgroup under pressure. Above all NO
    #    MemoryMax: that would make it killable from inside its cgroup.
    #  - OOMScoreAdjust=-1000: the kernel OOM killer excludes it.
    #  - StartLimitIntervalSec=0: systemd never gives up restarting again.
    #
    # CHILDREN inherit the cgroup: the MCP servers and the sub-processes
    # of tasks (builds, browsers, scripts) are bounded by this same weight.
    systemd.slices.hermes = {
      description = "Hermes Agent (interactive priority)";
      sliceConfig = {
        CPUWeight = 2000;
        IOWeight = 1000;
        # Hardware reservation: the threads of physical cores 6 and 7
        # (cpu12 to cpu15) belong to Hermes, excluded from background.slice. Even under
        # a 12-thread build, the gateway keeps 2 whole physical cores.
        # A WEIGHT alone guarantees nothing in absolute terms; cpuset does.
        # Until 21/11/2026 the reservation was 1 core (cpu12-13): a
        # gateway with two tasks serialized on it. Widened to 2 cores.
        # Accepted trade-off: the sub-processes of tasks (builds,
        # browsers launched by an agent) inherit the cpuset and run on
        # these 4 threads. Heavy work must go to the fleet (Windmill).
        # Only applies if the host declares services.hermes.cpuIsolation.
      } // lib.optionalAttrs (config.services.hermes.cpuIsolation != null) {
        AllowedCPUs = config.services.hermes.cpuIsolation;
      };
    };

    # `member` excludes no one: system.slice/user.slice can still
    # run on the reserved CPUs. We promote the slice to cgroup v2 root
    # partition, which makes them exclusive to Hermes and its descendants.
    # No boot parameter (isolcpus) needed. Trade-off: these CPUs are no
    # longer usable by the rest of the system, even when Hermes is idle.
    # Only on hosts that declare cpuIsolation (tower).
    systemd.services.hermes-cpuset = lib.mkIf (config.services.hermes.cpuIsolation != null) {
      description = "Promotes hermes.slice to a cpuset root partition (${config.services.hermes.cpuIsolation} exclusive)";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes.slice" ];
      before = [ "hermes-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "hermes-cpuset" ''
          set -eu
          cg=/sys/fs/cgroup/hermes.slice
          desired=${config.services.hermes.cpuIsolation}
          # Adding cpus cannot fail in itself; the fallback covers the case
          # where the kernel refuses to hot-modify an already-active partition.
          if ! echo "$desired" > "$cg/cpuset.cpus.exclusive" 2>/dev/null; then
            echo member > "$cg/cpuset.cpus.partition"
            echo "$desired" > "$cg/cpuset.cpus.exclusive"
          fi
          if [ "$(cat "$cg/cpuset.cpus.partition")" != "root" ]; then
            echo root > "$cg/cpuset.cpus.partition"
          fi
        '';
      };
    };
    systemd.services.hermes-agent = {
      # A NixOS rebuild must not cut the gateway: its tasks live
      # inside it. restartIfChanged=false => switch-to-configuration updates
      # the unit file but does not restart the running process; the
      # new config applies at the next manual start.
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
    # The backend serves the desktop and the web terminal: same treatment.
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

    # --- Opus for Discord voice ---
    # The Hermes Discord adapter (plugins/platforms/discord/adapter.py) loads
    # libopus via ctypes.util.find_library("opus"), which on NixOS finds nothing:
    # no /etc/ld.so.cache, and the gcc/ld fallback fails for lack of binaries. The
    # fallback `ld -L <LD_LIBRARY_PATH> -lopus` + `objdump` works with binutils
    # on the PATH (extraPackages), and LD_LIBRARY_PATH is needed IN the
    # process environment from startup: dlopen("libopus.so.0") uses the value read
    # by ld.so at launch, a variable added later via .env is not
    # enough. It is the env of the systemd UNIT (the module's `environment` option, for
    # its part, only writes $HERMES_HOME/.env).
    # Verified: find_library -> libopus.so.0, discord.opus.is_loaded() -> True,
    # Decoder/Encoder opus instantiable.
    systemd.services.hermes-agent.environment.LD_LIBRARY_PATH = "${pkgs.libopus}/lib";

    # --- Desktop plugin: vim-keybindings (declarative, managed by nix) ---
    # Creates the plugin in /var/lib/hermes/.hermes/desktop-plugins/vim-bindings/
    # via tmpfiles + oneshot service at the start of the hermes service.
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes/.hermes/desktop-plugins 0755 hermes hermes -"
      "d /var/lib/hermes/.hermes/desktop-plugins/vim-bindings 0755 hermes hermes -"
      # Catppuccin theme of the web dashboard: the file lives in this repo and arrives
      # in the Hermes home by store symlink (the dashboard only reads, so the
      # 0444 of the store is enough). The file name AND the `name:` of the YAML must
      # stay equal, otherwise _discover_user_themes() silently ignores it.
      "d /var/lib/hermes/.hermes/dashboard-themes 0755 hermes hermes -"
      "L+ /var/lib/hermes/.hermes/dashboard-themes/catppuccin-mocha-lavender.yaml - hermes hermes - ${./dashboard-themes/catppuccin-mocha-lavender.yaml}"
      # Hermes skin (CLI + TUI + desktop): the YAML lives in this repo but is
      # COPIED, not symlinked, by the activation script below. Why: the
      # gateway's change_watcher watches the mtime of the active skin file, and a
      # store file keeps mtime=1, so a symlink NEVER repaints the
      # desktop after a color tweak. The copy takes a fresh mtime at
      # each switch, which triggers `skin.changed` without a gateway restart.
      "d /var/lib/hermes/.hermes/skins 0755 hermes hermes -"
      "a /home/marc - - - - u:hermes:--x,m::--x"
      "a /home/marc/git - - - - u:hermes:--x,m::r-x"
      # Repos outside nixos: hermes only has --x on /home/marc/git, so it can
      # only create a new repo when the directory already exists with an ACL.
      # mcp-rust (Rust MCP servers) is created here once and for all; add one
      # line per new repo instead of widening the parent directory.
      "d /home/marc/git/mcp-rust 2775 marc dev -"
      "a /home/marc/git/mcp-rust - - - - u:hermes:rwX"
    ];

    # Skin copy at each activation (see the tmpfiles comment): fresh
    # mtime => `skin.changed` => desktop, CLI and TUI repainted without restart.
    system.activationScripts."hermes-skin" = ''
      install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/skins
      install -m 0644 -o hermes -g hermes ${./skins/claude-code.yaml} \
        /var/lib/hermes/.hermes/skins/claude-code.yaml
    '';

        # --- vim-bindings plugin: DISABLED (JS heredoc parsing issues in Nix)
        # systemd.services.hermes-vim-bindings-plugin = { ... };
    })

    # --- Nextcloud MCP: see services/nextcloud-mcp (single_user_basic, loopback) ---
  ];
}
