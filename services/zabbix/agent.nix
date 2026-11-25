# services/zabbix/agent.nix: Zabbix agent of the monitored machines.
#
# The server lives on the VPS (services/zabbix/server.nix, imported only by
# profiles/anywhere). The agents reach it over the TAILNET (100.64.0.1), not
# from the outside: `networking.firewall.trustedInterfaces = [ "tailscale0" ]`
# (services/tailscale) is enough, no port to open, and the traffic is already
# encrypted by WireGuard.
{ config, pkgs, ... }:
let
  # anywhere (the VPS), tailnet address. The server listens on 0.0.0.0:10051.
  server = "100.64.0.1";
  # Same series as the server (7.4 LTS): an agent older than the server
  # works, a newer agent breaks, so we align the two to
  # never have to think about it during a version upgrade.
  package = pkgs.zabbix74.agent;
in
{
  services.zabbixAgent = {
    enable = true;
    inherit package;

    # Passive checks: the server queries the agent, coming back over the
    # tailnet. The module's `server` option feeds the `Server` line of the
    # config file, it accepts a comma-separated list.
    server = server;

    settings = {
      # Active checks: the agent pushes to the server.
      ServerActive = "${server}:10051";
      # Host name on the server side. It is this name that must exist in Zabbix
      # (hosts are created by the API: Zabbix keeps its inventory in its
      # database, not in nix).
      Hostname = config.networking.hostName;
    };
  };
}
