# services/mcp-lan-access/default.nix
#
# Rend cliquables depuis le Mac de marc les URLs des serveurs MCP HTTP qui
# écoutent en loopback sur tower (nextcloud 8710, anki 3141, arrmcp 6060,
# beeper 23373). Hermes Desktop affiche l'URL de `mcp_servers.<nom>.url` telle
# quelle dans Capabilities -> MCP : en loopback, le clic part sur le localhost
# du Mac et ne peut pas répondre.
#
# Principe : un redirecteur TCP par port, qui écoute sur l'adresse LAN de tower
# et relaie vers 127.0.0.1. systemd-socket-proxyd est un proxy TCP pur : il ne
# touche pas aux en-têtes HTTP, donc les flux SSE / streamable HTTP des serveurs
# MCP passent intacts (pas de buffering nginx à régler).
#
# Sécurité : le firewall NixOS (backend iptables sur tower) n'accepte ces ports
# que depuis `clientAddress` (le Mac). Les ports ne vont JAMAIS dans
# allowedTCPPorts, et les services eux-mêmes restent sur la loopback. Le trafic
# de tower vers sa propre adresse LAN sort par lo (interface de confiance), donc
# Hermes continue de joindre les mêmes URLs sans règle supplémentaire.
#
# Le couple adresse/port est dupliqué dans les URLs MCP : changer `host` ici
# met à jour les quatre URLs du même coup (chaque module service lit cette
# option). Si wlan0 change d'adresse DHCP, mettre `host` à jour et rebuild.
{ config, lib, ... }:
let
  cfg = config.services.mcp-lan-access;

  forwards = lib.mapAttrsToList (name: port: { inherit name port; }) cfg.endpoints;

  unitName = f: "mcp-lan-${f.name}";
in {
  options.services.mcp-lan-access = {
    enable = lib.mkEnableOption "accès LAN filtré aux endpoints MCP loopback de tower";

    host = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.44";
      description = ''
        Adresse LAN de tower sur laquelle les redirecteurs écoutent. Sert aussi
        de base aux URLs MCP des modules nextcloud-mcp, arr-mcp, anki-mcp et au
        serveur beeper déclaré dans services/hermes.
      '';
    };

    clientAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.48";
      description = "Seule adresse source que le firewall accepte sur ces ports.";
    };

    endpoints = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = { };
      example = {
        nextcloud = 8710;
        anki = 3141;
      };
      description = "Attribut nom -> port loopback à republier sur `host`.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.sockets = lib.listToAttrs (map (f: {
      name = unitName f;
      value = {
        description = "Redirecteur LAN ${cfg.host}:${toString f.port} vers 127.0.0.1:${toString f.port}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${cfg.host}:${toString f.port}" ];
        # wlan0 est en DHCP : FreeBind crée le socket avant que l'adresse existe
        # au boot ; il accepte dès que l'adresse est posée. Sans ça, le socket
        # unit échoue en "Cannot assign requested address" au démarrage.
        socketConfig.FreeBind = true;
      };
    }) forwards);

    systemd.services = lib.listToAttrs (map (f: {
      name = unitName f;
      value = {
        description = "Redirecteur LAN vers MCP ${f.name} (127.0.0.1:${toString f.port})";
        requires = [ "${unitName f}.socket" ];
        after = [ "${unitName f}.socket" ];
        serviceConfig = {
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --connections-max=64 127.0.0.1:${toString f.port}";
          DynamicUser = true;
          PrivateTmp = true;
        };
      };
    }) forwards);

    networking.firewall.extraCommands = lib.concatMapStrings (f:
      "iptables -w -A nixos-fw -p tcp -s ${cfg.clientAddress} --dport ${toString f.port} -j nixos-fw-accept\n"
    ) forwards;

    assertions = [{
      assertion = !(lib.any (f: lib.elem f.port config.networking.firewall.allowedTCPPorts) forwards);
      message = "mcp-lan-access : ne pas mettre ces ports dans networking.firewall.allowedTCPPorts ; la règle filtrée par source de ce module suffit.";
    }];
  };
}
