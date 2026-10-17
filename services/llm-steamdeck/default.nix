{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.llm-steamdeck;

  # Default model configuration - Qwen3.5-9B Q4_K_M (~6.17 GB)
  defaultModel = {
    repo = "bartowski/Qwen_Qwen3.5-9B-GGUF";
    file = "Qwen3.5-9B-Q4_K_M.gguf";
    contextSize = 8192;
  };

  # Alternative: TheStageAI Qwen3.5-9B Q4_K_M (~5.06 GB, slightly smaller)
  altModel = {
    repo = "TheStageAI/Qwen3.5-9B-GGUF";
    file = "Qwen3.5-9B-M-TS-Q4_K_M.gguf";
    contextSize = 8192;
  };

  # Model to use (can be overridden)
  model = if cfg.modelRepo != null then {
    repo = cfg.modelRepo;
    file = cfg.modelFile or "Qwen3.5-9B-Q4_K_M.gguf";
    contextSize = cfg.contextSize or 8192;
  } else defaultModel;

  # Download model on first run using llama.cpp's built-in HF support
  modelPath = "/var/lib/llm-steamdeck/${model.repo}/${model.file}";

in {
  options.services.llm-steamdeck = {
    enable = mkEnableOption "llama.cpp OpenAI-compatible server for Steam Deck (Vulkan)";

    # Model configuration
    modelRepo = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Hugging Face repository for the GGUF model (e.g. 'bartowski/Qwen_Qwen3.5-9B-GGUF'). Null uses default Qwen3.5-9B Q4_K_M.";
    };
    modelFile = mkOption {
      type = types.str;
      default = "Qwen3.5-9B-Q4_K_M.gguf";
      description = "GGUF filename within the repository.";
    };
    contextSize = mkOption {
      type = types.int;
      default = 8192;
      description = "Context window size. 8192 recommended for 16GB RAM; 16384 possible in headless mode.";
    };

    # Server configuration
    port = mkOption {
      type = types.portNumber;
      default = 8080;
      description = "Port for the OpenAI-compatible API server.";
    };
    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Host to bind to. Use '127.0.0.1' for local-only access.";
    };

    # GPU/performance options
    gpuLayers = mkOption {
      type = types.int;
      default = 99;
      description = "Number of layers to offload to GPU (Vulkan). 99 = all layers. Reduce if OOM.";
    };
    threads = mkOption {
      type = types.int;
      default = 8;
      description = "CPU threads for llama.cpp (Steam Deck has 8 cores).";
    };
    batchSize = mkOption {
      type = types.int;
      default = 512;
      description = "Batch size for prompt processing. Lower if prefill OOM.";
    };
    ubatchSize = mkOption {
      type = types.int;
      default = 512;
      description = "Micro-batch size for prompt processing.";
    };
    flashAttn = mkOption {
      type = types.bool;
      default = true;
      description = "Enable flash attention (requires llama.cpp with Qwen3.5 support).";
    };

    # Sampling defaults (can be overridden per-request)
    temperature = mkOption {
      type = types.float;
      default = 0.7;
      description = "Default sampling temperature.";
    };
    topP = mkOption {
      type = types.float;
      default = 0.95;
      description = "Default top-p sampling.";
    };
    topK = mkOption {
      type = types.int;
      default = 20;
      description = "Default top-k sampling.";
    };
    repeatPenalty = mkOption {
      type = types.float;
      default = 1.1;
      description = "Default repeat penalty.";
    };

    # Service management
    user = mkOption {
      type = types.str;
      default = "deck";
      description = "User to run the service as.";
    };
    group = mkOption {
      type = types.str;
      default = "deck";
      description = "Group for the service.";
    };
    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments passed to llama-server.";
    };

    # Model download
    autoDownload = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically download model on first start via llama.cpp HF support.";
    };
    hfToken = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Hugging Face token for private/gated models (set via sops secret).";
    };

    # Web UI
    enableWebUI = mkOption {
      type = types.bool;
      default = true;
      description = "Enable built-in web UI at /";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Vulkan support for RADV (Steam Deck AMD GPU)
    hardware.opengl.enable = true;
    hardware.opengl.driSupport = true;
    hardware.opengl.driSupport32Bit = true;

    # Vulkan ICD loader for llama.cpp
    environment.systemPackages = with pkgs; [
      vulkan-tools
      vulkan-loader
      mesa
      mesa.drivers
      mesa_glu
    ];

    # Create model directory with proper permissions
    systemd.tmpfiles.rules = [
      "d /var/lib/llm-steamdeck 0755 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/llm-steamdeck/${model.repo} 0755 ${cfg.user} ${cfg.group} - -"
    ];

    # Pre-download model if autoDownload enabled (using llama-cli --hf-repo)
    systemd.services.llm-steamdeck-download = {
      description = "Download LLM model from Hugging Face";
      documentation = [ "https://github.com/ggml-org/llama.cpp" ];
      wantedBy = [ "multi-user.target" ];
      before = [ "llm-steamdeck.service" ];
      conditionPathExists = "!${modelPath}";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = ''
          ${pkgs.llama-cpp-vulkan}/bin/llama-cli \
            --hf-repo ${model.repo} \
            --hf-file ${model.file} \
            --model ${modelPath} \
            -p " " \
            -n 1 \
            ${lib.optionalString (cfg.hfToken != null) "--hf-token ${cfg.hfToken}"}
        '';
        Environment = [
          "HOME=/home/${cfg.user}"
          "XDG_CACHE_HOME=/home/${cfg.user}/.cache"
        ];
        StateDirectory = "llm-steamdeck";
        TimeoutStartSec = 1800; # 30 min for download
      };
    };

    # Main llama-server service
    systemd.services.llm-steamdeck = {
      description = "llama.cpp OpenAI-compatible server (Vulkan) for Steam Deck";
      documentation = [
        "https://github.com/ggml-org/llama.cpp"
        "https://huggingface.co/${model.repo}"
      ];
      after = [ "network-online.target" "llm-steamdeck-download.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/var/lib/llm-steamdeck";
        ExecStart = ''
          ${pkgs.llama-cpp-vulkan}/bin/llama-server \
            --model ${modelPath} \
            --host ${cfg.host} \
            --port ${toString cfg.port} \
            --ctx-size ${toString model.contextSize} \
            --n-gpu-layers ${toString cfg.gpuLayers} \
            --threads ${toString cfg.threads} \
            --batch-size ${toString cfg.batchSize} \
            --ubatch-size ${toString cfg.ubatchSize} \
            --temp ${toString cfg.temperature} \
            --top-p ${toString cfg.topP} \
            --top-k ${toString cfg.topK} \
            --repeat-penalty ${toString cfg.repeatPenalty} \
            ${lib.optionalString cfg.flashAttn "--flash-attn"} \
            ${lib.optionalString cfg.enableWebUI "--web-ui"} \
            ${lib.optionalString (cfg.hfToken != null) "--hf-token ${cfg.hfToken}"} \
            ${concatStringsSep " " cfg.extraArgs}
        '';
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        # Memory limits for Steam Deck 16GB unified RAM
        MemoryMax = "12G";
        MemorySwapMax = "2G";
        # GPU access
        SupplementaryGroups = [ "video" "render" ];
        Environment = [
          "VK_ICD_FILENAMES=/etc/vulkan/icd.d/radeon_icd.x86_64.json:/etc/vulkan/icd.d/radeon_icd.i686.json"
          "RADV_PERFTEST=aco,nggc,mesh_shaders"
          "AMD_DEBUG=w32ge,w32cs"
          "HOME=/home/${cfg.user}"
          "XDG_CACHE_HOME=/home/${cfg.user}/.cache"
          "XDG_RUNTIME_DIR=/run/user/1000"
        ];
        # Logging
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "llm-steamdeck";
      };
    };

    # Enable and start services
    systemd.services.llm-steamdeck-download.enable = cfg.autoDownload;
    systemd.services.llm-steamdeck.enable = true;

    # Firewall opening for local network access
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # User setup (ensure deck user has video/render groups)
    users.users.${cfg.user} = {
      extraGroups = [ "video" "render" ];
    };

    # Convenience: systemd user service alias for easy management
    systemd.user.services.llm-steamdeck = {
      description = "User-level alias for llm-steamdeck";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl --user start llm-steamdeck.service";
        RemainAfterExit = true;
      };
    };

    # Logrotate for llama-server logs (uses systemd journal, logrotate not needed for journald)
    # services.logrotate = {
    #   enable = true;
    #   settings."llm-steamdeck" = {
    #     path = [ "/var/log/journal/*/system.journal" ];
    #     rotate = 7;
    #     daily = true;
    #     compress = true;
    #     missingok = true;
    #     notifempty = true;
    #   };
    # };
  };
}