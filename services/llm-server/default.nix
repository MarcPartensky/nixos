{ config, lib, pkgs, ... }:
# Serveur LLM multi-modeles du portable RTX 3060 (provider Hermes `laptop-llama`).
#
# Historique : l'unite llm-server.service tournait encore en /nix/store alors que
# plus AUCUN fichier du depot ne la declarait (module perdu, constate 2026-11-14).
# Consequence vecue : son ExecStart pointait sur un yaml gele en /nix/store, build
# Vulkan sans `-rea off`, donc un port 8080 qui repondait a /v1/models mais ne
# rendait jamais de reponse (la generation partait en raisonnement illimite).
# Ce module remet la declaration dans le depot.
#
# Le yaml reste un fichier VIVANT (/var/lib/llm-server/llama-swap.yaml) : c'est la
# surface de reglage (ajout de modeles, ttl), editable sans rebuild. Ce module ne
# declare que l'unite qui le lit.
let
  cfg = config.services.llm-server;
  dataDir = "/var/lib/llm-server";
in
{
  options.services.llm-server = {
    enable = lib.mkEnableOption "llama-swap sur le portable (port 8080, provider laptop-llama)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port d'ecoute compatible OpenAI.";
    };

    llamaServer = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/llama-cpp-cuda/bin/llama-server";
      description = ''
        Binaire llama-server utilise par les modeles du yaml (macro `llamacuda`).
        Par defaut le build CUDA ad hoc du portable (sm_86 ; recette dans le skill
        nixos-ml-inference) : `nix build -o /var/lib/hermes/llama-cpp-cuda`
        maintient ce chemin comme GC root.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${dataDir}/llama-swap.yaml";
      description = "Yaml llama-swap (source de verite des modeles servis).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 hermes hermes - -"
      "d ${dataDir}/models 0755 hermes hermes - -"
    ];

    systemd.services.llm-server = {
      description = "Serveur LLM local (llama.cpp derriere llama-swap)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # llama-swap lance les enfants llama-server ; nvidia-smi dans le PATH permet
      # le monitoring VRAM (/running, web UI).
      environment = {
        HOME = "/var/lib/hermes";
        XDG_CACHE_HOME = "/var/lib/hermes/.cache";
        # mkForce : nixos/modules/system/boot/systemd.nix pose deja un PATH par
        # defaut (coreutils/findutils/gnugrep) ; on veut /run/current-system/sw/bin
        # en tete pour que le monitoring VRAM de llama-swap trouve nvidia-smi.
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
