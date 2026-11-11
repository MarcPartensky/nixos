{
  config,
  lib,
  pkgs,
  ...
}:

# Serveur MCP de synthese vocale (Phonon, Kokoro, OmniVoice, Ming,
# Chatterbox, Breeze) destine au PORTABLE, le seul noeud de la flotte qui a
# les moteurs, les poids telecharges et la RTX 3060. Toute generation de voix
# passe donc par cette machine, quelle que soit celle qui parle a l'agent :
# l'agent de tower s'y connecte en HTTP sur le tailnet (interface tailscale0,
# seule interface de confiance du pare-feu).
#
# Pourquoi un service HTTP et pas un MCP stdio sur tower : les moteurs vivent
# dans des environnements python qui n'existent QUE sur le portable (venvs pip
# du banc d'essai ~/tts-bench, plus l'environnement kokoro du store). Un
# serveur qui vit la ou sont les moteurs garde les modeles chauds entre deux
# appels, ce que le CLI ne fait pas.
#
# Le code du serveur (tts_mcp.py) est du python pur (stdlib + SDK mcp) ; le
# worker (worker.py) tourne DANS l'interpreteur du moteur choisi, donc ses
# imports (ptts, kokoro, torch, ming_tts, chatterbox) ne melangent rien.
{
  options.services.tts-mcp = {
    enable = lib.mkEnableOption "Serveur MCP de synthese vocale sur le portable";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8092;
      description = ''
        Port d'ecoute HTTP (streamable MCP sur /mcp). Pas besoin de l'ouvrir :
        le pare-feu ne fait confiance qu'a tailscale0, donc le serveur n'est
        joignable que dans le tailnet.
      '';
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Adresse d'ecoute. 0.0.0.0 est sur tant que seul tailscale0 est de confiance.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "Utilisateur qui execute le serveur (proprietaire du banc d'essai).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
    };

    benchDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/tts-bench";
      description = ''
        Banc d'essai TTS du portable : venvs pip des moteurs, poids telecharges
        a la main, scripts. Imperatif par nature (roues pip, modeles), donc
        reference par chemin et verifie par le tool `status`.
      '';
    };

    warmTtlSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = "Duree pendant laquelle un moteur reste charge (modele chaud) apres son dernier appel.";
    };

    hfTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Fichier contenant HF_TOKEN, pour les poids gates (phonon-40m-multilingual
        n'est telechargeable qu'apres acceptation des conditions sur Hugging
        Face). Sans lui, seul l'anglais de Phonon est disponible.
      '';
    };
  };

  config =
    let
      cfg = config.services.tts-mcp;

      # Environnement kokoro : le paquet nixpkgs fournit kokoro + torch ; le
      # modele spacy anglais (en_core_web_sm) n'est PAS telechargeable par
      # spacy sans pip, donc misaki[en] echoue sans lui -- le wheel extrait
      # dans le banc d'essai suffit via PYTHONPATH.
      kokoroEnv = pkgs.python3.withPackages (ps: [ ps.kokoro ps.numpy ]);

      bench = cfg.benchDir;
      espeak = pkgs.espeak-ng;
      ffmpeg = pkgs.ffmpeg;

      # Les roues manylinux de torch ont besoin des bibliotheques du systeme :
      # sans /run/opengl-driver/lib, torch.cuda.is_available() reste False
      # meme avec le pilote installe.
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
          label = "Phonon 31M (gradium, Apache-2.0) : anglais, CPU, le plus rapide";
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
          note = "Le catalogue (gradium/phonon-voices) couvre en/de/es/fr/pt, mais les voix non anglaises exigent le modele 40m-multilingual, GATE sur Hugging Face : sans jeton accepte, seul l'anglais sort proprement.";
        };

        kokoro = {
          label = "Kokoro 82M v1.0 (hexgrad, Apache-2.0) : francais (1 voix) et anglais, CPU";
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
          note = "En francais une seule voix (ff_siwis, la meme que Piper siwis) : c'est le plafond du modele, aucun mastering ne le depasse.";
        };

        omni = {
          label = "OmniVoice 0,6B (k2-fsa) : 600+ langues, GPU, poids CC-BY-NC";
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
              kind = "profil instruct";
            }
            {
              name = "female, middle-aged, moderate pitch";
              language = "fr,en,600+";
              kind = "profil instruct";
            }
            {
              name = "female, elderly, low pitch";
              language = "fr,en,600+";
              kind = "profil instruct";
            }
            {
              name = "male, young adult, moderate pitch";
              language = "fr,en,600+";
              kind = "profil instruct";
            }
            {
              name = "male, middle-aged, moderate pitch";
              language = "fr,en,600+";
              kind = "profil instruct";
            }
            {
              name = "male, elderly, low pitch";
              language = "fr,en,600+";
              kind = "profil instruct";
            }
            {
              name = "<chemin.wav>";
              language = "*";
              kind = "clonage (ref_audio, ~12 s suffisent)";
            }
          ];
          load_timeout = 900;
          say_timeout = 1200;
          env = { PYTHONPATH = "${bench}/omni"; };
          note = "Prose refusee : la voix est un profil du vocabulaire ferme, ou un clonage par ref_audio. Licence : code Apache-2.0 mais POIDS CC-BY-NC, aucun usage commercial.";
        };

        ming = {
          label = "Ming-3.0-tts 0,5B (inclusionAI, MIT) : FR/EN + 5, GPU";
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
              kind = "voix interne";
            }
            {
              name = "UK_George";
              language = "en-gb";
              kind = "voix interne";
            }
            {
              name = "freeform:<instruction>";
              language = "*";
              kind = "description libre";
            }
            {
              name = "<chemin.wav>";
              language = "fr,en";
              kind = "clonage (ref_audio, exige ref_text)";
            }
          ];
          load_timeout = 900;
          say_timeout = 1200;
          env = { PYTHONPATH = "${bench}/Ming-3.0-tts"; };
          note = "pynini absent : la normalisation de texte est desactivee, donc ecrire les nombres en mots.";
        };

        cb = {
          label = "Chatterbox Multilingual V3 (Resemble AI, MIT, retire en 2026) : GPU, sortie filigranee";
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
              language = "23 langues";
              kind = "voix interne";
            }
            {
              name = "<chemin.wav>";
              language = "23 langues";
              kind = "clonage (ref_audio)";
            }
          ];
          load_timeout = 900;
          say_timeout = 1800;
          env = { TTS_CB_MODEL_DIR = "${bench}/models/chatterbox"; };
          note = "Filigrane Perth dans la sortie : a savoir avant publication.";
        };

        breeze = {
          label = "Breeze TTS 2 (GGUF q4_k, binaire Vulkan) : EN/ZH, GPU, licence recherche non commerciale";
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
          note = "RTF ~7 mesure : correct pour une replique, pas pour un episode de 20 min (2 h 30 de GPU).";
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
        description = "Serveur MCP de synthese vocale (Phonon, Kokoro, OmniVoice, Ming, Chatterbox, Breeze)";
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
          # Les rendus longs sont des process detaches : ne pas les tuer avec
          # le serveur, ils doivent survivre a un redemarrage du service.
          KillMode = "process";
          TimeoutStopSec = 20;
        };
      };

      # Le serveur ne doit etre joignable QUE dans le tailnet : le port n'est
      # ouvert que sur tailscale0 (aucun autre ajout au pare-feu, donc la
      # carte wifi du portable ne l'expose pas).
      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
    };
}
