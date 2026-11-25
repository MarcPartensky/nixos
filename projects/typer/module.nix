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
      description = "Port loopback du serveur HTTP/WebSocket.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix {}";
      description = ''
        Paquet typer : `typer-server` et `typer-race`, plus le front-end
        statique sous share/typer/web.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.typer = {
      description = "typer : entrainement a la frappe (web + salons de course)";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        ExecStart = "${cfg.package}/bin/typer-server --root ${cfg.package}/share/typer/web --port ${toString cfg.port}";
        Restart = "always";
        RestartSec = 3;

        # Le service ne lit que son propre repertoire du store et sert du HTTP
        # en clair derriere newt.
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

    # `typer-race` : client terminal des salons, meme serveur /ws que le
    # navigateur. ttyper (nixpkgs) reste l'exercice solo.
    environment.systemPackages = [cfg.package];

    # Pas d'ouverture au firewall : l'acces reseau passe par newt (loopback).
  };
}
