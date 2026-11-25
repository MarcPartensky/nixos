# services/mcp-lan-access/default.nix
#
# Makes the URLs of the HTTP MCP servers that listen on loopback on tower
# clickable from marc's Mac (nextcloud 8710, anki 3141, arrmcp 6060).
# Hermes Desktop displays the URL of `mcp_servers.<name>.url` as
# is in Capabilities -> MCP: on loopback, the click goes to the Mac's
# localhost and cannot answer.
#
# Principle: one TCP redirector per port, listening on tower's LAN address
# and relaying to 127.0.0.1. systemd-socket-proxyd is a pure TCP proxy: it does not
# touch the HTTP headers, so the SSE / streamable HTTP streams of the MCP
# servers pass through intact (no nginx buffering to tune).
#
# Security: the NixOS firewall (iptables backend on tower) accepts these ports
# only from `clientAddress` (the Mac). The ports NEVER go into
# allowedTCPPorts, and the services themselves stay on loopback. Tower's traffic
# to its own LAN address goes out through lo (trusted interface), so
# Hermes keeps reaching the same URLs without an extra rule.
#
# The address/port pair is duplicated in the MCP URLs: changing `host` here
# updates the four URLs at once (each service module reads this
# option). If wlan0 changes DHCP address, update `host` and rebuild.
{ config, lib, ... }:
let
  cfg = config.services.mcp-lan-access;

  forwards = lib.mapAttrsToList (name: port: { inherit name port; }) cfg.endpoints;

  unitName = f: "mcp-lan-${f.name}";
in {
  options.services.mcp-lan-access = {
    enable = lib.mkEnableOption "filtered LAN access to tower's loopback MCP endpoints";

    host = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.44";
      description = ''
        Tower's LAN address on which the redirectors listen. Also serves
        as the base for the MCP URLs of the nextcloud-mcp, arr-mcp and anki-mcp modules.
      '';
    };

    clientAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.48";
      description = "Only source address the firewall accepts on these ports.";
    };

    endpoints = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = { };
      example = {
        nextcloud = 8710;
        anki = 3141;
      };
      description = "Attribute name -> loopback port to republish on `host`.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.sockets = lib.listToAttrs (map (f: {
      name = unitName f;
      value = {
        description = "LAN redirector ${cfg.host}:${toString f.port} to 127.0.0.1:${toString f.port}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${cfg.host}:${toString f.port}" ];
        # wlan0 is on DHCP: FreeBind creates the socket before the address exists
        # at boot; it accepts as soon as the address is set. Without it, the socket
        # unit fails with "Cannot assign requested address" at startup.
        socketConfig.FreeBind = true;
      };
    }) forwards);

    systemd.services = lib.listToAttrs (map (f: {
      name = unitName f;
      value = {
        description = "LAN redirector to MCP ${f.name} (127.0.0.1:${toString f.port})";
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
      message = "mcp-lan-access: do not put these ports in networking.firewall.allowedTCPPorts; this module's source-filtered rule is enough.";
    }];
  };
}
