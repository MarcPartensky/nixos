# services/uptime-kuma: end-to-end availability monitor.
#
# Fills the gap that Zabbix does not see the same way: it probes the
# PUBLIC domains from the outside (HTTP, TCP), so it catches an exposure
# failure (newt tunnel down, Pangolin resource in 502, expired certificate)
# even when all the machines are fine. This is exactly the failure that
# stayed invisible for 26 h on 10/11.
#
# Hosted on the VPS, like Zabbix: a monitor that lives on the machine it
# watches cannot announce its own failure. Note: Gotify and Matrix
# run on TOWER, so their alerts are mute when tower goes down; for
# that case, the reverse probe is on the tower side and the alert must leave from the VPS
# (mail via stalwart, which lives here).
#
# Footprint: Node, on the order of 0.5 to 1% CPU and 150 to 250 MB. The UI and the
# probes live in SQLite (/var/lib/uptime-kuma): it is not Postgres, but
# it is a single file, trivial to back up (and the upstream Postgres request
# is still open).
#
# The service runs as DynamicUser with a strict systemd sandbox and
# AmbientCapabilities = "": the ICMP (ping) probes therefore cannot open
# a raw socket. We monitor the machines via TCP (port 22 on the tailnet),
# which is just as informative, and the domains via HTTP.
#
# Access: Pangolin resource `uptime.marcpartensky.com` to 127.0.0.1:3001, as
# a local target of the rack site, WITHOUT SSO: the Android client (OpenKuma) and the API do not
# follow a login redirect. Uptime Kuma has its own account and its
# 2FA to compensate.
{ ... }:
{
  services.uptime-kuma = {
    enable = true;

    settings = {
      # Loopback: it is traefik (Pangolin) that exposes, not the firewall.
      HOST = "127.0.0.1";
      PORT = "3001";
      DATA_DIR = "/var/lib/uptime-kuma/";
      UPTIME_KUMA_DB_TYPE = "sqlite";
    };
  };
}
