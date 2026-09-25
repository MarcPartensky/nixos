{
  lib,
  config,
  pkgs,
  ...
}:
# Client Eternal Terminal : ouvre (ou crée) une session zellij sur l'hôte distant
# et l'enregistre côté serveur avec asciinema (script `et-session`, cf.
# services/eternal-terminal/default.nix — module côté serveur).
#
# et lit ~/.ssh/config : les alias `ssh` existants (modules/home/ssh) servent donc
# aussi de cibles à `et <alias>`.
let
  cfg = config.my.et;

  hostModule =
    { name, ... }:
    {
      options = {
        remoteCommand = lib.mkOption {
          type = lib.types.str;
          default = cfg.remoteCommand;
          description = ''
            Commande lancée sur l'hôte distant à la connexion. Chemin absolu de
            préférence : le PATH des shells non interactifs distants n'est pas garanti.
          '';
        };
        session = lib.mkOption {
          type = lib.types.str;
          default = cfg.defaultSession;
          description = "Nom de la session zellij à attacher (créée si absente).";
        };
        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Utilisateur distant (`et -u`) ; null = celui de ~/.ssh/config.";
        };
        port = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "Port de l'etserver distant (`et -p`), défaut ET = 2022 ; null = défaut.";
        };
        functionName = lib.mkOption {
          type = lib.types.str;
          default = "et${name}";
          description = "Nom de la fonction zsh générée.";
        };
      };
    };
in

{
  options.my.et = {
    enable = lib.mkEnableOption "connexions Eternal Terminal avec zellij et enregistrement automatiques";

    defaultSession = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Session zellij par défaut (surchargée par ET_SESSION).";
    };

    remoteCommand = lib.mkOption {
      type = lib.types.str;
      default = "/run/current-system/sw/bin/et-session";
      description = ''
        Commande de session distante. Le défaut est le chemin absolu du script
        installé par services/eternal-terminal (chemin stable sur NixOS).
      '';
    };

    wrapEt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Redéfinir `et` en fonction zsh : `et <hôte>` attache zellij enregistré,
        tout appel avec option (`et -v 3 hôte`, `et -t 10080:80 hôte`) passe
        directement au binaire.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule hostModule);
      default = { };
      example = {
        tower = {
          port = 2022;
        };
        towerlocal = { };
      };
      description = ''
        Alias à exposer : chaque entrée `name` génère une fonction zsh `etname`.
        `name` doit être un hôte/alias présent dans ~/.ssh/config.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.eternal-terminal ];

    programs.zsh.initContent = lib.mkAfter (
      let
        mkFunction =
          name: h:
          let
            flags = lib.escapeShellArgs (
              lib.optionals (h.user != null) [ "-u" h.user ]
              ++ lib.optionals (h.port != null) [ "-p" (toString h.port) ]
              ++ [ name ]
            );
          in
          ''
            ${h.functionName}() {
              command et ${flags} -c ${lib.escapeShellArg "${h.remoteCommand} ${h.session}"}
            }
          '';
      in
      ''
        # --- my.et : Eternal Terminal + zellij + enregistrement asciinema ---

        # Attache (ou crée) une session zellij distante enregistrée : ets <hôte> [session]
        ets() {
          local host="${"$"}{1:?usage: ets <hôte> [session]}"
          shift
          local session="${"$"}{1:-${"$"}{ET_SESSION:-${cfg.defaultSession}}}"
          command et "$host" -c "${"$"}{ET_REMOTE_COMMAND:-${cfg.remoteCommand}} $session"
        }

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkFunction cfg.hosts)}
      ''
      + lib.optionalString cfg.wrapEt ''
        # et <hôte> (sans option) = zellij enregistré ; le reste passe au binaire.
        et() {
          if (( $# >= 1 )) && [[ "$1" != -* ]]; then
            command et "$@" -c "${"$"}{ET_REMOTE_COMMAND:-${cfg.remoteCommand}} ${"$"}{ET_SESSION:-${cfg.defaultSession}}"
          else
            command et "$@"
          fi
        }
      ''
    );
  };
}
