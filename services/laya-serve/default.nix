# NixOS module: local decision service "System One" (Jev-compatible API),
# intended for tower. Laya is a non-autoregressive decision engine, Apache-2.0:
# you send it a state (text, JSON) plus typed questions (choice / score /
# noul) and it returns a probability distribution in ONE forward pass, without
# generating a single token. It is the free equivalent of TypeSafe's Jev model, which
# is neither open nor self-hostable.
#
# WHY this module rather than the upstream one: the upstream flake
# (github:NandhaKishorM/laya, nix/laya-serve.nix) builds its package with
# `python3Packages.torch-bin`, the prebuilt CUDA wheel, and its unit allows the
# /dev/nvidia* devices. tower has no NVIDIA GPU (Vega Renoir iGPU): the
# CUDA closure would weigh several GB for zero use. Here laya is built
# from the PyPI sdist with nixpkgs' CPU torch, and the unit takes the upstream
# shape (systemd hardening, StateDirectory for the weights cache).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.laya-serve;

  # laya 0.4.21: library plus the CLIs `laya`, `laya-serve`, `laya-mcp-server`.
  # The sdist is pinned by SRI hash, so a reproducible build, without
  # network calls. Upstream imports fastapi/uvicorn lazily, we declare them
  # anyway: `laya-serve` must start without a missing dependency.
  laya = pkgs.python3Packages.buildPythonApplication {
    pname = "laya";
    version = "0.4.21";
    format = "setuptools";
    src = pkgs.fetchPypi {
      pname = "laya";
      version = "0.4.21";
      hash = "sha256-kTCgxfKiEC8xfPAgm+e69orpuZabXttx2iYEDaZ8UwE=";
    };
    propagatedBuildInputs = with pkgs.python3Packages; [
      torch # CPU: tower has no NVIDIA GPU, pointless to pull torch-bin
      transformers
      safetensors
      huggingface-hub
      numpy
      fastapi
      uvicorn
      multipart # python-multipart, for the example server's uploads
    ];
    # Upstream tests load checkpoints from the Hub: network and GPU.
    doCheck = false;
    pythonImportsCheck = [ "laya" "laya.serve" ];
  };

  # The token (optional) arrives via LoadCredential: never in the store nor
  # in the unit's environment.
  startScript = pkgs.writeShellScript "laya-serve-start" ''
    set -eu
    ${lib.optionalString (cfg.apiKeyFile != null) ''
      export LAYA_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/apikey")"
    ''}
    exec ${cfg.package}/bin/laya-serve
  '';
in
{
  options.services.laya-serve = {
    enable = lib.mkEnableOption "Laya decision server (Jev-compatible API, /v1/systemone)";

    package = lib.mkOption {
      type = lib.types.package;
      default = laya;
      defaultText = lib.literalExpression "laya (built from the PyPI sdist, CPU torch)";
      description = "laya-serve package to run.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Listen address. 127.0.0.1 by default: the service renders decisions,
        it has no reason to be reachable anywhere but locally. Go through
        a Pangolin resource (SSO) if remote access is wanted.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Listening TCP port.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "cpu";
      example = "cuda";
      description = "torch device for each checkpoint (cpu, cuda, cuda:0, ...).";
    };

    models = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "english" "multilingual" "typed-decisions" ]);
      default = [ "english" "multilingual" "typed-decisions" ];
      description = ''
        Checkpoints preloaded at startup. The router then chooses according to the
        language of the received state (marc writes in French and English, so
        multilingual is not decorative).
      '';
    };

    preload = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build the checkpoints at startup rather than on the first request.
        true avoids paying the load in the middle of an agent loop; the
        first start then downloads about 1.2 GiB of weights.
      '';
    };

    threads = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 8;
      example = 16;
      description = ''
        torch thread cap for CPU inference (sets LAYA_THREADS and
        OMP_NUM_THREADS). tower = Ryzen 7 4800H, 8 physical cores out of 16
        logical: stay at 8 for the latency of an isolated request, go up
        to 16 only for batch throughput.
      '';
    };

    autoTaskDetection = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let the router choose the typed-decisions checkpoint when the questions match its workflows.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.laya-api-key.path";
      description = ''
        File containing a bearer token. When it is set, clients must
        send `Authorization: Bearer <token>`.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port` on the firewall (pointless as long as host stays on loopback).";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "laya-serve";
      description = "Name under /var/lib for the Hugging Face weights cache (HF_HOME).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.laya-serve = {
      description = "Laya: System One decision server (Jev-compatible API)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        LAYA_HOST = cfg.host;
        LAYA_PORT = toString cfg.port;
        LAYA_DEVICE = cfg.device;
        LAYA_PRELOAD = if cfg.preload then "1" else "0";
        LAYA_MODELS = lib.concatStringsSep "," cfg.models;
        LAYA_AUTO_TASK = if cfg.autoTaskDetection then "1" else "0";
        HF_HOME = "/var/lib/${cfg.stateDirectory}/huggingface";
      } // lib.optionalAttrs (cfg.threads != null) {
        LAYA_THREADS = toString cfg.threads;
        OMP_NUM_THREADS = toString cfg.threads;
      };

      serviceConfig = {
        ExecStart = startScript;
        Restart = "on-failure";
        RestartSec = 5;
        # First start: download of the weights before listening.
        TimeoutStartSec = "900";

        DynamicUser = true;
        StateDirectory = cfg.stateDirectory;

        # No GPU: no PrivateDevices = false nor DeviceAllow, unlike
        # the upstream module which opens the /dev/nvidia* nodes.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      } // lib.optionalAttrs (cfg.apiKeyFile != null) {
        LoadCredential = [ "apikey:${cfg.apiKeyFile}" ];
      };
    };

    # `laya` and `laya-serve` in the PATH: used to test a decision by hand
    # (echo '{"state":...,"questions":...}' | laya ...) without going through the API.
    environment.systemPackages = [ cfg.package ];

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
