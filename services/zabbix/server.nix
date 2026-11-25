# services/zabbix/server.nix: Zabbix server + web frontend, hosted on the VPS.
#
# Why here and not on tower: the monitoring server must survive what
# it monitors. tower reboots about once a day and its outgoing
# traffic depends on the newt tunnel; the VPS has held a single boot for months and
# it is already the control plane for all domains. Frontend and database stay
# therefore on the VPS, the agents (services/zabbix/agent.nix) go on the machines.
#
# Footprint: it is the heaviest brick of the three (C server + PHP frontend
# + already-present Postgres), we accept it on the VPS (4 vCPU, load < 1) and we
# never put it on tower. The agents, for their part, are negligible (~15 MB, < 0.1%).
#
# Database: Postgres local to the VPS, user and database `zabbix`, created by
# ensureUsers/ensureDatabases. Auth: connection via 127.0.0.1, where the rule
# `host all all 127.0.0.1/32 trust` (services/postgres) applies first,
# so NO password to carry in sops. This is already the regime of the other
# tower databases (everything is in trust locally), and port 5432 is reachable
# only from loopback and the tailnet.
#
# The frontend listens on LOOPBACK on 9600: 80/443 belong to traefik
# (Pangolin), so nginx must definitely not take the port. Public access
# goes through a Pangolin resource `zabbix.marcpartensky.com` as a local target of the
# rack site (created by the integration API: the newt blueprint only serves
# targets of a newt site, not the control plane host).
# The package is NOT the nixpkgs default (`pkgs.zabbix` = 6.0 LTS): see
# the header of the `let` block for the why of 7.4 LTS.
{ config, lib, pkgs, ... }:
let
  port = 9600;
  domain = "zabbix.marcpartensky.com";

  # 7.4 LTS and not the nixpkgs default 6.0. Three reasons measured on
  # 15/11/2026: the 6.0 frontend runs PHP 8.4 (the one from 26.05)
  # which emits E_DEPRECATED on every page (`session_set_save_handler` with
  # individual callbacks), which Zabbix's error handler displays
  # plainly in the middle of the interface; 6.0 is officially supported only
  # up to PostgreSQL 15 while the VPS runs 17.11; and 7.4 is the
  # current LTS (redesigned UI, PHP 8.4/8.5 supported). The database migration is
  # direct from 6.0.x (Zabbix doc "Upgrade procedure"). A dump of the
  # 6.0 database is kept in /root on the VPS before any move to 7.4.
  zabbix = pkgs.zabbix74;
in
{
  services.postgresql = {
    ensureDatabases = [ "zabbix" ];
    ensureUsers = [
      {
        name = "zabbix";
        ensureDBOwnership = true;
      }
    ];
  };

  services.zabbixServer = {
    enable = true;
    package = zabbix.server;

    database = {
      type = "pgsql";
      host = "127.0.0.1";
      name = "zabbix";
      user = "zabbix";
    };

    # Reachable from the tailnet by the agents (trappers). The VPS firewall
    # opens nothing: tailscale0 is trusted (services/tailscale).
    listen.ip = "0.0.0.0";
    listen.port = 10051;
    openFirewall = false;

    # No `settings` for now: the default values are sized
    # for far more than six hosts, and an unknown key in zabbix_server.conf
    # makes the server exit at startup. We will tune the pollers after the
    # first real load measurement.
  };

  services.zabbixWeb = {
    enable = true;
    package = zabbix.web;
    frontend = "nginx";
    hostname = domain;

    server = {
      address = "127.0.0.1";
      port = 10051;
    };

    database = {
      type = "pgsql";
      host = "127.0.0.1";
      name = "zabbix";
      user = "zabbix";
    };

    nginx.virtualHost = {
      # Loopback only, and especially NOT port 80: traefik serves all the
      # VPS domains there. forceSSL/addSSL stay false, it is traefik that
      # terminates TLS.
      listen = [
        {
          addr = "127.0.0.1";
          port = port;
        }
      ];
      forceSSL = false;
      addSSL = false;
    };
  };

  # Belt and suspenders: if a vhost were to not declare its `listen`, it
  # would fall back on this default instead of port 80.
  services.nginx.defaultListen = [
    {
      addr = "127.0.0.1";
      port = port;
    }
  ];

  # The local agent: the VPS monitors itself (disk, RAM, services), which
  # covers the outage that already took down the whole stack (full disk on 10/11).
  services.zabbixAgent = {
    enable = true;
    # `package` comes from services/zabbix/agent.nix (same 7.4 series): defining it
    # here too creates a conflict of definitions in the module.
    # 127.0.0.1 in addition to the tailnet: the "Zabbix server" host of the
    # database queries 127.0.0.1:10050 (local interface). With only 100.64.0.1, this
    # agent refused the connection and the dashboard permanently showed
    # "Zabbix agent is not available" on the server itself.
    # mkForce: services/zabbix/agent.nix (imported right next to it by the profile)
    # already sets `server`, two definitions of the same priority are a conflict.
    server = lib.mkForce "100.64.0.1,127.0.0.1";
    settings = {
      ServerActive = "100.64.0.1:10051";
      Hostname = config.networking.hostName;
    };
  };

  # Deliberate reminder: the `zabbix` database lives on the VPS, of which NO database is
  # backed up today (pqbox dumps tower's databases). To add to the
  # backup chain, like the vault if it comes back here.
  warnings = [
    "Zabbix: the database on the VPS is not covered by pqbox (cf. services/backup-pqbox)."
  ];
}
