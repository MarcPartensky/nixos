# NixOS module for typer.marcpartensky.com, exported as `nixosModules.default`.
#
# The system flake consumes it from a copy vendored at projects/typer:
#
#   inputs.typer = { url = "path:./projects/typer"; inputs.nixpkgs.follows = "nixpkgs"; };
#
#   imports = [ inputs.typer.nixosModules.default ];
#   services.typer.enable = true;
#
# The service is loopback only: the public path is Pangolin -> newt (tower) ->
# 127.0.0.1:9146. Path inputs are re-copied on every eval, so a modified
# projects/typer lands on the next switch; `nix flake lock` is only needed for
# a new input.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.typer;
in {
  options.services.typer = {
    enable = lib.mkEnableOption "typer.macpartensky.com (typing drills and race rooms)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9146;
      description = "Loopback port of the HTTP/WebSocket server.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix {}";
      description = ''
        typer package: `typer-server` and `typer-race`, plus the static
        front-end under share/typer/web.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.typer = {
      description = "typer: typing practice (web + race rooms)";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        ExecStart = "${cfg.package}/bin/typer-server --root ${cfg.package}/share/typer/web --port ${toString cfg.port}";
        Restart = "always";
        RestartSec = 3;

        # The service only reads its own store directory and serves plain HTTP
        # behind newt.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        MemoryDenyWriteExecute = true;
      };
    };

    # `typer-race`: terminal client for the rooms, same /ws server as the
    # browser. ttyper (nixpkgs) remains the solo exercise.
    environment.systemPackages = [cfg.package];

    # No firewall opening: network access goes through newt (loopback).
  };
}
