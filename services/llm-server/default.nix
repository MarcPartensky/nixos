{ config, lib, pkgs, ... }:
# Multi-model LLM server of the RTX 3060 laptop (Hermes provider `laptop-llama`).
#
# History: the llm-server.service unit was still running from /nix/store while
# NO file in the repo declared it anymore (lost module, observed 2026-11-14).
# Consequence experienced: its ExecStart pointed to a frozen yaml in /nix/store, a Vulkan
# build without `-rea off`, so port 8080 answered /v1/models but never
# returned a response (generation ran off into unlimited reasoning).
# This module puts the declaration back in the repo.
#
# The yaml remains a LIVE file (/var/lib/llm-server/llama-swap.yaml): it is the
# tuning surface (adding models, ttl), editable without a rebuild. This module
# only declares the unit that reads it.
let
  cfg = config.services.llm-server;
  dataDir = "/var/lib/llm-server";
in
{
  options.services.llm-server = {
    enable = lib.mkEnableOption "llama-swap on the laptop (port 8080, provider laptop-llama)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "OpenAI-compatible listen port.";
    };

    llamaServer = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/llama-cpp-cuda/bin/llama-server";
      description = ''
        llama-server binary used by the models of the yaml (macro `llamacuda`).
        By default the laptop's ad hoc CUDA build (sm_86; recipe in the skill
        nixos-ml-inference): `nix build -o /var/lib/hermes/llama-cpp-cuda`
        keeps this path as a GC root.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${dataDir}/llama-swap.yaml";
      description = "llama-swap yaml (source of truth of the served models).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 hermes hermes - -"
      "d ${dataDir}/models 0755 hermes hermes - -"
    ];

    systemd.services.llm-server = {
      description = "Local LLM server (llama.cpp behind llama-swap)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # llama-swap launches the llama-server children; nvidia-smi in the PATH allows
      # VRAM monitoring (/running, web UI).
      environment = {
        HOME = "/var/lib/hermes";
        XDG_CACHE_HOME = "/var/lib/hermes/.cache";
        # mkForce: nixos/modules/system/boot/systemd.nix already sets a default
        # PATH (coreutils/findutils/gnugrep); we want /run/current-system/sw/bin
        # first so that llama-swap's VRAM monitoring finds nvidia-smi.
        PATH = lib.mkForce "/run/current-system/sw/bin:/usr/bin:/bin";
      };
      serviceConfig = {
        Type = "simple";
        User = "hermes";
        Group = "hermes";
        WorkingDirectory = dataDir;
        ExecStart = "${pkgs.llama-swap}/bin/llama-swap -config ${cfg.configFile} -listen 0.0.0.0:${toString cfg.port} -watch-config";
        Restart = "always";
        RestartSec = 5;
        KillMode = "mixed";
        TimeoutStopSec = 30;
        ManagedOOMPreference = "avoid";
        SupplementaryGroups = [ "video" "render" ];
      };
    };
  };
}
