{
  lib,
  config,
  pkgs,
  ...
}:
# Eternal Terminal client: opens (or creates) a zellij session on the remote host
# and records it server-side with asciinema (script `et-session`, see
# services/eternal-terminal/default.nix -- server-side module).
#
# and reads ~/.ssh/config: the existing `ssh` aliases (modules/home/ssh) therefore also
# serve as targets for `et <alias>`.
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
            Command run on the remote host on connection. Absolute path
            preferred: the PATH of remote non-interactive shells is not guaranteed.
          '';
        };
        session = lib.mkOption {
          type = lib.types.str;
          default = cfg.defaultSession;
          description = "Name of the zellij session to attach (created if absent).";
        };
        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Remote user (`et -u`); null = the one from ~/.ssh/config.";
        };
        port = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "Port of the remote etserver (`et -p`), ET default = 2022; null = default.";
        };
        functionName = lib.mkOption {
          type = lib.types.str;
          default = "et${name}";
          description = "Name of the generated zsh function.";
        };
      };
    };
in

{
  options.my.et = {
    enable = lib.mkEnableOption "automatic Eternal Terminal connections with zellij and recording";

    defaultSession = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Default zellij session (overridden by ET_SESSION).";
    };

    remoteCommand = lib.mkOption {
      type = lib.types.str;
      default = "/run/current-system/sw/bin/et-session";
      description = ''
        Remote session command. The default is the absolute path of the script
        installed by services/eternal-terminal (stable path on NixOS).
      '';
    };

    wrapEt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Redefine `et` as a zsh function: `et <host>` attaches a recorded zellij,
        any call with an option (`et -v 3 host`, `et -t 10080:80 host`) goes
        directly to the binary.
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
        Aliases to expose: each `name` entry generates a zsh function `etname`.
        `name` must be a host/alias present in ~/.ssh/config.
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
        # --- my.et: Eternal Terminal + zellij + asciinema recording ---

        # Attach (or create) a recorded remote zellij session: ets <host> [session]
        ets() {
          local host="${"$"}{1:?usage: ets <host> [session]}"
          shift
          local session="${"$"}{1:-${"$"}{ET_SESSION:-${cfg.defaultSession}}}"
          command et "$host" -c "${"$"}{ET_REMOTE_COMMAND:-${cfg.remoteCommand}} $session"
        }

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkFunction cfg.hosts)}
      ''
      + lib.optionalString cfg.wrapEt ''
        # et <host> (no option) = recorded zellij; the rest goes to the binary.
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
