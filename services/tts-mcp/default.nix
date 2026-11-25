{
  config,
  lib,
  pkgs,
  ...
}:

# Speech synthesis MCP server (Phonon, Kokoro, OmniVoice, Ming,
# Chatterbox, Breeze) dedicated to the LAPTOP, the only node of the fleet that has
# the engines, the downloaded weights and the RTX 3060. All voice generation
# therefore goes through this machine, whichever one talks to the agent:
# the tower agent connects to it over HTTP on the tailnet (tailscale0 interface,
# the only interface the firewall trusts).
#
# Why an HTTP service and not an MCP stdio on tower: the engines live
# in python environments that exist ONLY on the laptop (pip venvs
# of the test bench ~/tts-bench, plus the kokoro environment from the store). A
# server that lives where the engines are keeps the models warm between two
# calls, which the CLI does not do.
#
# The server code (tts_mcp.py) is pure python (stdlib + mcp SDK); the
# worker (worker.py) runs INSIDE the interpreter of the chosen engine, so its
# imports (ptts, kokoro, torch, ming_tts, chatterbox) mix nothing.
{
  options.services.tts-mcp = {
    enable = lib.mkEnableOption "Speech synthesis MCP server on the laptop";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8092;
      description = ''
        HTTP listening port (streamable MCP on /mcp). No need to open it:
        the firewall only trusts tailscale0, so the server is only
        reachable inside the tailnet.
      '';
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Listening address. 0.0.0.0 is safe as long as only tailscale0 is trusted.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "User that runs the server (owner of the test bench).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
    };

    benchDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/tts-bench";
      description = ''
        TTS test bench of the laptop: pip venvs of the engines, weights downloaded
        by hand, scripts. Imperative by nature (pip wheels, models), so
        referenced by path and checked by the `status` tool.
      '';
    };

    warmTtlSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = "Duration for which an engine stays loaded (warm model) after its last call.";
    };

    hfTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing HF_TOKEN, for the gated weights (phonon-40m-multilingual
        can only be downloaded after accepting the terms on Hugging
        Face). Without it, only Phonon's English is available.
      '';
    };

    openaiBridge = {
      enable = lib.mkEnableOption ''
        OpenAI-compatible facade (POST /v1/audio/speech) in front of the MCP server,
        for applications that only speak the OpenAI audio API
        (Open Notebook, Open WebUI, LiteLLM). The model is chosen in the
        form "<engine>-<language>" (kokoro-fr, omni-en, kokoro-en-gb...)
      '';
      port = lib.mkOption {
        type = lib.types.port;
        default = 8093;
        description = "Port of the OpenAI-compatible facade (tailnet only).";
      };
    };
  };

  config =
    let
      cfg = config.services.tts-mcp;

      # Kokoro environment: the nixpkgs package provides kokoro + torch; the
      # English spacy model (en_core_web_sm) is NOT downloadable by
      # spacy without pip, so misaki[en] fails without it -- the wheel extracted
      # into the test bench is enough via PYTHONPATH.
      kokoroEnv = pkgs.python3.withPackages (ps: [ ps.kokoro ps.numpy ]);

      bench = cfg.benchDir;
      espeak = pkgs.espeak-ng;
      ffmpeg = pkgs.ffmpeg;

      # The manylinux wheels of torch need the system libraries:
      # without /run/opengl-driver/lib, torch.cuda.is_available() stays False
      # even with the driver installed.
      ldPath = lib.concatStringsSep ":" [
        "${espeak}/lib"
        "${pkgs.stdenv.cc.cc.lib}/lib"
        "${pkgs.zlib}/lib"
        "${pkgs.libsndfile}/lib"
        "/run/opengl-driver/lib"
      ];

      path = lib.concatStringsSep ":" [
        "${espeak}/bin"
        "${ffmpeg}/bin"
        "${pkgs.python3}/bin"
        "/run/current-system/sw/bin"
        "/run/wrappers/bin"
        "/var/lib/hermes/.local/bin"
      ];

      engines = {
        phonon = {
          label = "Phonon 31M (gradium, Apache-2.0): English, CPU, the fastest";
          kind = "python";
          python = "${bench}/envs/phonon/bin/python";
          languages = [ "en" ];
          default_language = "en";
          default_voice = { en = "Harper"; };
          gpu = false;
          voices_source = "worker";
          load_timeout = 300;
          say_timeout = 600;
          env = {
            TTS_PHONON_QUANT = "q8";
            TTS_PHONON_MODELS = builtins.toJSON {
              en = "hf://gradium/phonon-31m-en";
              multi = "hf://gradium/phonon-40m-multilingual";
            };
          };
          note = "The catalog (gradium/phonon-voices) covers en/de/es/fr/pt, but the non-English voices require the 40m-multilingual model, GATED on Hugging Face: without an accepted token, only English comes out cleanly.";
        };

        kokoro = {
          label = "Kokoro 82M v1.0 (hexgrad, Apache-2.0): French (1 voice) and English, CPU";
          kind = "python";
          python = "${kokoroEnv}/bin/python";
          languages = [
            "en"
            "en-us"
            "en-gb"
            "fr"
            "es"
            "it"
            "pt"
            "hi"
            "ja"
            "zh"
          ];
          default_language = "en";
          default_voice = {
            en = "af_heart";
            fr = "ff_siwis";
          };
          gpu = false;
          voices_source = "worker";
          load_timeout = 300;
          say_timeout = 600;
          env = {
            PYTHONPATH = "${bench}/spacy-models";
            TTS_KOKORO_VOICES_DIR = "${bench}/kokoro-voices";
          };
          note = "In French only one voice (ff_siwis, the same as Piper siwis): it is the model's ceiling, no mastering goes beyond it.";
        };

        omni = {
          label = "OmniVoice 0.6B (k2-fsa): 600+ languages, GPU, CC-BY-NC weights";
          kind = "python";
          python = "${bench}/envs/gpuvenv/bin/python";
          languages = [
            "fr"
            "en"
            "es"
            "de"
            "it"
            "pt"
            "zh"
            "ja"
            "ko"
          ];
          default_language = "fr";
          default_voice = {
            fr = "female, young adult, high pitch";
            en = "male, middle-aged, moderate pitch";
          };
          gpu = true;
          voices_source = "static";
          voices = [
            {
              name = "female, young adult, high pitch";
              language = "fr,en,600+";
              kind = "instruct profile";
            }
            {
              name = "female, middle-aged, moderate pitch";
              language = "fr,en,600+";
              kind = "instruct profile";
            }
            {
              name = "female, elderly, low pitch";
              language = "fr,en,600+";
              kind = "instruct profile";
            }
            {
              name = "male, young adult, moderate pitch";
              language = "fr,en,600+";
              kind = "instruct profile";
            }
            {
              name = "male, middle-aged, moderate pitch";
              language = "fr,en,600+";
              kind = "instruct profile";
            }
            {
              name = "male, elderly, low pitch";
              language = "fr,en,600+";
              kind = "instruct profile";
            }
            {
              name = "<path.wav>";
              language = "*";
              kind = "cloning (ref_audio, ~12 s is enough)";
            }
          ];
          load_timeout = 900;
          say_timeout = 1200;
          env = { PYTHONPATH = "${bench}/omni"; };
          note = "Prose refused: the voice is a profile of the closed vocabulary, or a clone via ref_audio. License: code Apache-2.0 but WEIGHTS CC-BY-NC, no commercial use.";
        };

        ming = {
          label = "Ming-3.0-tts 0.5B (inclusionAI, MIT): FR/EN + 5, GPU";
          kind = "python";
          python = "${bench}/envs/ming/bin/python";
          languages = [
            "en"
            "fr"
            "de"
            "es"
            "ja"
            "ko"
          ];
          default_language = "en";
          default_voice = {
            en = "UK_George";
            fr = "US_Emma";
          };
          gpu = true;
          voices_source = "static";
          voices = [
            {
              name = "US_Emma";
              language = "en-us";
              kind = "built-in voice";
            }
            {
              name = "UK_George";
              language = "en-gb";
              kind = "built-in voice";
            }
            {
              name = "freeform:<instruction>";
              language = "*";
              kind = "free-form description";
            }
            {
              name = "<path.wav>";
              language = "fr,en";
              kind = "cloning (ref_audio, requires ref_text)";
            }
          ];
          load_timeout = 900;
          say_timeout = 1200;
          env = { PYTHONPATH = "${bench}/Ming-3.0-tts"; };
          note = "pynini absent: text normalization is disabled, so write numbers as words.";
        };

        cb = {
          label = "Chatterbox Multilingual V3 (Resemble AI, MIT, retired in 2026): GPU, watermarked output";
          kind = "python";
          python = "${bench}/envs/cb/bin/python";
          languages = [
            "en"
            "fr"
            "de"
            "es"
            "it"
            "pt"
            "zh"
            "ja"
            "ko"
          ];
          default_language = "en";
          default_voice = {
            en = "builtin";
            fr = "builtin";
          };
          gpu = true;
          voices_source = "static";
          voices = [
            {
              name = "builtin";
              language = "23 languages";
              kind = "built-in voice";
            }
            {
              name = "<path.wav>";
              language = "23 languages";
              kind = "cloning (ref_audio)";
            }
          ];
          load_timeout = 900;
          say_timeout = 1800;
          env = { TTS_CB_MODEL_DIR = "${bench}/models/chatterbox"; };
          note = "Perth watermark in the output: worth knowing before publishing.";
        };

        breeze = {
          label = "Breeze TTS 2 (GGUF q4_k, Vulkan binary): EN/ZH, GPU, non-commercial research license";
          kind = "cli";
          python = "${kokoroEnv}/bin/python";
          languages = [ "en" "zh" ];
          default_language = "en";
          default_voice = { en = "builtin"; };
          gpu = true;
          voices_source = "worker";
          load_timeout = 300;
          say_timeout = 1800;
          env = {
            TTS_BREEZE_BIN = "${bench}/models/breeze/bin/breeze-tts-2-v0.1.7-linux-x64-vulkan/breeze-cli";
            TTS_BREEZE_GGUF = "${bench}/models/breeze/breeze-tts-2-q4_k.gguf";
            LD_LIBRARY_PATH = "/run/opengl-driver/lib:${pkgs.vulkan-loader}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.zlib}/lib";
          };
          note = "RTF ~7 measured: fine for one line, not for a 20 min episode (2 h 30 of GPU).";
        };
      };

      engineConfig = pkgs.writeText "tts-mcp-engines.json" (
        builtins.toJSON {
          bench_dir = bench;
          jobs_dir = "${bench}/jobs-mcp";
          out_dir = "${bench}/out-mcp";
          worker = "${./worker.py}";
          ffmpeg = "${ffmpeg}/bin/ffmpeg";
          ffprobe = "${ffmpeg}/bin/ffprobe";
          host = cfg.bindAddress;
          port = cfg.port;
          warm_ttl_seconds = cfg.warmTtlSeconds;
          path = path;
          ld_library_path = ldPath;
          master_chain = lib.concatStringsSep "," [
            "highpass=f=85"
            "deesser=i=0.4"
            "acompressor=threshold=-18dB:ratio=3:attack=4:release=150"
            "equalizer=f=2800:t=q:w=1.1:g=2"
            "equalizer=f=180:t=q:w=1:g=-1.5"
            "loudnorm=I=-16:TP=-1.5:LRA=11"
          ];
          inherit engines;
        }
      );

      server = pkgs.writers.writePython3Bin "tts-mcp" {
        libraries = [ pkgs.python3Packages.mcp ];
        flakeIgnore = [
          "E501"
          "W503"
          "E265"
        ];
      } (builtins.readFile ./tts_mcp.py);

      # OpenAI-compatible facade: separate process, with no dependency, that
      # translates /v1/audio/speech into a call to the MCP server's "say" tool.
      # Separated from the MCP server so that a third-party app cannot
      # bring it down and so that it can be cut without losing the warm engines.
      bridge = pkgs.writers.writePython3Bin "tts-openai-bridge" {
        flakeIgnore = [
          "E501"
          "W503"
        ];
      } (builtins.readFile ./tts_openai_bridge.py);

      bin = pkgs.writeShellApplication {
        name = "tts-mcp-service";
        runtimeInputs = [
          espeak
          ffmpeg
          pkgs.coreutils
        ];
        text = ''
          export PATH="${path}:$PATH"
          export LD_LIBRARY_PATH="${ldPath}"
          ${lib.optionalString (cfg.hfTokenFile != null)
            "export HF_TOKEN=\"$(cat ${cfg.hfTokenFile})\""}
          exec ${server}/bin/tts-mcp
        '';
      };
    in
    lib.mkIf cfg.enable {
      systemd.services.tts-mcp = {
        description = "Speech synthesis MCP server (Phonon, Kokoro, OmniVoice, Ming, Chatterbox, Breeze)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = {
          TTS_CONFIG = "${engineConfig}";
          HF_HOME = "/var/lib/hermes/.cache/huggingface";
          HF_HUB_DISABLE_PROGRESS_BARS = "1";
          PYTHONUNBUFFERED = "1";
        };
        serviceConfig = {
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = bench;
          ExecStart = "${bin}/bin/tts-mcp-service";
          Restart = "always";
          RestartSec = 5;
          # Long renders are detached processes: do not kill them with
          # the server, they must survive a restart of the service.
          KillMode = "process";
          TimeoutStopSec = 20;
        };
      };

      # The server must be reachable ONLY inside the tailnet: the port is
      # opened only on tailscale0 (no other addition to the firewall, so the
      # laptop's wifi card does not expose it).
      networking.firewall.interfaces.tailscale0.allowedTCPPorts =
        [ cfg.port ] ++ lib.optional cfg.openaiBridge.enable cfg.openaiBridge.port;

      systemd.services.tts-openai = lib.mkIf cfg.openaiBridge.enable {
        description = "OpenAI-compatible facade (/v1/audio/speech) in front of tts-mcp";
        wantedBy = [ "multi-user.target" ];
        after = [ "tts-mcp.service" ];
        requires = [ "tts-mcp.service" ];
        serviceConfig = {
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${bridge}/bin/tts-openai-bridge --host ${cfg.bindAddress} --port ${toString cfg.openaiBridge.port} --mcp-url http://127.0.0.1:${toString cfg.port}/mcp";
          Restart = "always";
          RestartSec = 5;
        };
      };
    };
}
