{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

# Immich machine learning on the LAPTOP, with its RTX 3060.
#
# Why here and not on tower: on the tower side the service consumes ~1.9 core
# during the 4 h of the nightly indexing window (4.6 h of CPU per 24 h
# measured on 15/11/2026) and tower has neither CUDA nor ROCm (Vega). The laptop is
# already the rendering node of the fleet (tts-mcp, llm-server), it never
# suspends and its 3060 is idle most of the time.
#
# Why this module rebuilds everything: the `onnxruntime` package of nixpkgs is
# built CPU-only (`onnxruntime_USE_CUDA=OFF`). Immich has nothing to change on
# its side, `immich_ml` chooses its providers at runtime:
#   immich_ml/models/constants.py -> SUPPORTED_PROVIDERS, CUDA first
#   immich_ml/sessions/ort.py     -> [p for p in SUPPORTED_PROVIDERS
#                                     if p in ort.get_available_providers()]
# So it is enough that onnxruntime exposes CUDAExecutionProvider. The chain is:
#   onnxruntime (cudaSupport) -> python3 with this onnxruntime
#   -> immich.machine-learning rebuilt on top of it.
# The nixpkgs python onnxruntime module already handles the CUDA case: it reads
# `onnxruntime.passthru.cudaSupport` and adds cublas/curand/cufft/cudnn/cudart
# to buildInputs, so autoPatchelf sets the rpath.
#
# The Immich server stays on tower (it reads /srv/photos locally) and points
# here via IMMICH_MACHINE_LEARNING_URL, cf. services/immich/default.nix over there.
let
  cfg = config.services.immich-ml;

  # All packages come from the SAME nixpkgs as the immich of tower (input
  # unstable): the ML and the server must be the same version, otherwise
  # Immich rejects the responses (internal API contract between the two).
  # Instance separate from `pkgs` because unfree must be allowed there: cuDNN,
  # cuBLAS and CCCL are under the CUDA EULA. `nixpkgs.config` of the host does not
  # apply to a `legacyPackages` of an input.
  unstable = import inputs.unstable.outPath {
    system = pkgs.stdenv.hostPlatform.system;
    config = {
      allowUnfree = true;
    };
  };

  # onnxruntime CUDA. nccl disabled: a single card, no multi-GPU
  # communication to do.
  onnxruntimeCuda = unstable.onnxruntime.override {
    cudaSupport = true;
    ncclSupport = false;
    cudaPackages = unstable.cudaPackages.overrideScope (
      final: prev: {
        flags = prev.flags // {
          # Two pitfalls verified on onnxruntime 1.27 (external/
          # cuda_configuration.cmake:154, "Unrecognized CUDA architecture"):
          #   - the value does NOT carry the cmake option, nixpkgs adds it itself
          #     `-DCMAKE_CUDA_ARCHITECTURES=` (flags.nix: "75;86");
          #   - the architecture is written WITHOUT a dot ("86", nixpkgs dropDot
          #     convention), "8.6" is rejected by the configure.
          # The default blocked any rebuild of the laptop, hence indirectly this
          # workaround: the card stays the same, only the notation changes.
          cmakeCudaArchitecturesString = lib.replaceStrings ["."] [""] cfg.cudaArch;
        };
      }
    );
  };

  # The python onnxruntime package consumes `onnxruntime.dist` (the wheel produced
  # by the C++ build): we pass it the CUDA version, it will inherit the
  # cudnn/cublas rpath thanks to `passthru.cudaSupport`.
  pythonCuda = unstable.python3.override {
    packageOverrides = _self: prev: {
      onnxruntime = prev.onnxruntime.override { onnxruntime = onnxruntimeCuda; };
    };
  };

  ml = unstable.immich.machine-learning.override { python3 = pythonCuda; };
in
{
  options.services.immich-ml = {
    enable = lib.mkEnableOption "Immich machine learning on this node (CUDA GPU)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3003;
      description = ''
        HTTP listening port of the ML (same port as on tower, so the server's
        IMMICH_MACHINE_LEARNING_URL variable stays readable).
      '';
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.4";
      description = ''
        Listening address. We bind the laptop's tailscale address and not
        0.0.0.0: the firewall already only trusts tailscale0, but
        better that the port is not open at all on the wifi.
      '';
    };

    cudaArch = lib.mkOption {
      type = lib.types.str;
      default = "8.6";
      description = ''
        Compiled CUDA architecture. 8.6 = Ampere GA106 of the laptop's
        RTX 3060. Restricting to a single arch shortens the onnxruntime
        build from several hours to ~1 h (by default nixpkgs compiles
        the whole list of capabilities).
      '';
    };

    modelTtl = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Duration (s) for which a model stays loaded in VRAM after its
        last use. 300 = the GPU is given back to tts-mcp and llama-swap when
        indexing stops, without reloading for every photo during the window.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/immich-ml";
      description = ''
        Cache of the ONNX models (CLIP, insightface, OCR). Not to be confused
        with the data produced by the ML: that data (faces, search
        embeddings, OCR) is written by the SERVER into PostgreSQL on
        tower. The ML only returns vectors to the server, it persists nothing
        other than its models.
      '';
    };

    allowModelDownload = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Opens the service's Internet egress. Needed only on the FIRST
        start: immich_ml downloads its three models from HuggingFace
        and GitHub, then no longer needs to go out (the cache /var/cache/immich-ml
        is enough). Leave it false in normal operation, that is what makes the service
        unable to reach anything other than tower.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = ml;
      defaultText = lib.literalMD "`immich.machine-learning` rebuilt with CUDA `onnxruntime`";
      description = "Package of the machine learning service, with onnxruntime GPU.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups."immich-ml" = { };
    users.users."immich-ml" = {
      isSystemUser = true;
      group = "immich-ml";
      description = "Immich machine learning (laptop GPU)";
    };

    systemd.services.immich-machine-learning = {
      description = "Immich machine learning (CUDA GPU, laptop)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        IMMICH_HOST = cfg.bindAddress;
        IMMICH_PORT = toString cfg.port;
        MACHINE_LEARNING_CACHE_FOLDER = cfg.cacheDir;
        MACHINE_LEARNING_MODEL_TTL = toString cfg.modelTtl;
        MACHINE_LEARNING_WORKERS = "1";
        MACHINE_LEARNING_WORKER_TIMEOUT = "120";
        MACHINE_LEARNING_DEVICE_ID = "0";
        # insightface imports matplotlib unconditionally and wants a world-writable
        # cache; without these two variables it crashes on the first model.
        MPLCONFIGDIR = cfg.cacheDir;
        XDG_CACHE_HOME = cfg.cacheDir;
        # libcuda.so.1 comes from the driver, not from the CUDA toolkit: it is dlopen.
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        User = "immich-ml";
        Group = "immich-ml";
        CacheDirectory = "immich-ml";
        StateDirectory = "immich-ml";
        Restart = "on-failure";
        RestartSec = 5;
        # The GPU does the compute, the CPU only decodes the JPEGs: no
        # need to give it more than a few cores.
        CPUQuota = "300%";
        MemoryHigh = "6G";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;

        # -- Closed network: the ML only sees tower -------------------------
        # eBPF filter by cgroup. The service only accepts requests from
        # tower (100.64.0.3) and can only reach the loopback: no other
        # node of the tailnet can use it, and it cannot reach anything
        # else on the laptop. Outgoing traffic to the tailnet goes through the
        # tun, tailscaled encapsulates outside the cgroup, so DERP or DIRECT
        # changes nothing in the filter.
        IPAddressDeny = "any";
        IPAddressAllow =
          [
            "127.0.0.1/32"
            "::1/128"
            "100.64.0.3/32" # tower, the only legitimate client
          ]
          ++ lib.optionals cfg.allowModelDownload [
            "0.0.0.0/0" # HuggingFace + GitHub, first start only
            "::/0"
          ];
      };
    };

    # Reachable only inside the tailnet (same pattern as tts-mcp): no port
    # is added to the wifi firewall.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
