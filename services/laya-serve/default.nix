# Module NixOS : service de décision local « System One » (API compatible Jev),
# destiné à tower. Laya est un moteur de décision non autorégressif, Apache-2.0 :
# on lui envoie un état (texte, JSON) plus des questions typées (choice / score /
# noul) et il rend une distribution de probabilités en UNE passe avant, sans
# générer un seul token. C'est l'équivalent libre du modèle Jev de TypeSafe, qui
# n'est ni ouvert ni auto-hébergeable.
#
# POURQUOI ce module plutôt que celui du dépôt amont : le flake amont
# (github:NandhaKishorM/laya, nix/laya-serve.nix) construit son paquet avec
# `python3Packages.torch-bin`, le wheel CUDA prébuilt, et son unité autorise les
# périphériques /dev/nvidia*. tower n'a aucun GPU NVIDIA (iGPU Vega Renoir) : la
# closure CUDA pèserait plusieurs Go pour zéro usage. Ici laya est construit
# depuis le sdist PyPI avec le torch CPU de nixpkgs, et l'unité reprend la forme
# amont (durcissement systemd, StateDirectory pour le cache de poids).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.laya-serve;

  # laya 0.4.21 : bibliothèque plus les CLI `laya`, `laya-serve`, `laya-mcp-server`.
  # Le sdist est épinglé par empreinte SRI, donc un build reproductible, sans
  # appel réseau. L'amont importe fastapi/uvicorn paresseusement, on les déclare
  # quand même : `laya-serve` doit démarrer sans dépendance manquante.
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
      torch # CPU : tower n'a pas de GPU NVIDIA, inutile de tirer torch-bin
      transformers
      safetensors
      huggingface-hub
      numpy
      fastapi
      uvicorn
      multipart # python-multipart, pour les uploads du serveur d'exemple
    ];
    # Les tests amont chargent des checkpoints depuis le Hub : réseau et GPU.
    doCheck = false;
    pythonImportsCheck = [ "laya" "laya.serve" ];
  };

  # Le jeton (optionnel) arrive par LoadCredential : jamais dans le store ni
  # dans l'environnement de l'unité.
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
    enable = lib.mkEnableOption "serveur de décision Laya (API compatible Jev, /v1/systemone)";

    package = lib.mkOption {
      type = lib.types.package;
      default = laya;
      defaultText = lib.literalExpression "laya (built from the PyPI sdist, CPU torch)";
      description = "Paquet laya-serve à exécuter.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Adresse d'écoute. 127.0.0.1 par défaut : le service rend des décisions,
        il n'a aucune raison d'être joignable ailleurs qu'en local. Passer par
        une ressource Pangolin (SSO) si un accès distant est voulu.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port TCP d'écoute.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "cpu";
      example = "cuda";
      description = "Périphérique torch pour chaque checkpoint (cpu, cuda, cuda:0, ...).";
    };

    models = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "english" "multilingual" "typed-decisions" ]);
      default = [ "english" "multilingual" "typed-decisions" ];
      description = ''
        Checkpoints préchargés au démarrage. Le routeur choisit ensuite selon la
        langue de l'état reçu (marc écrit en français et en anglais, donc
        multilingual n'est pas décoratif).
      '';
    };

    preload = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Construire les checkpoints au démarrage plutôt qu'à la première requête.
        true évite de payer le chargement au milieu d'une boucle d'agent ; le
        premier démarrage télécharge alors environ 1,2 Gio de poids.
      '';
    };

    threads = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 8;
      example = 16;
      description = ''
        Plafond de threads torch pour l'inférence CPU (pose LAYA_THREADS et
        OMP_NUM_THREADS). tower = Ryzen 7 4800H, 8 cœurs physiques sur 16
        logiques : rester à 8 pour la latence d'une requête isolée, monter
        vers 16 seulement pour du débit en lot.
      '';
    };

    autoTaskDetection = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Laisser le routeur choisir le checkpoint typed-decisions quand les questions correspondent à ses workflows.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.laya-api-key.path";
      description = ''
        Fichier contenant un jeton bearer. Quand il est posé, les clients doivent
        envoyer `Authorization: Bearer <token>`.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Ouvrir `port` au pare-feu (inutile tant que host reste en loopback).";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "laya-serve";
      description = "Nom sous /var/lib pour le cache de poids Hugging Face (HF_HOME).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.laya-serve = {
      description = "Laya : serveur de décision System One (API compatible Jev)";
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
        # Premier démarrage : téléchargement des poids avant l'écoute.
        TimeoutStartSec = "900";

        DynamicUser = true;
        StateDirectory = cfg.stateDirectory;

        # Aucun GPU : pas de PrivateDevices = false ni de DeviceAllow, contrairement
        # au module amont qui ouvre les nœuds /dev/nvidia*.
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

    # `laya` et `laya-serve` dans le PATH : sert à tester une décision à la main
    # (echo '{"state":...,"questions":...}' | laya ...) sans passer par l'API.
    environment.systemPackages = [ cfg.package ];

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
