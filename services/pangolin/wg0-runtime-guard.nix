# wg0 runtime guard (Pangolin tunnel, newt clients), replayed every
# 5 minutes in addition to the startup hooks.
#
# Complement to gerbil-wg0-ensure.nix (which only covers the startup of
# gerbil): here we repair on the fly what a reboot, a switch or a service
# restart can break over time.
#
# 1. wg0 address: dhcpcd removed 100.89.128.1/24 on 2026-10-23 (carrier
#    rescan after the restart of dbus-broker/traefik), leaving the tunnel with
#    valid WireGuard handshakes but zero bytes of data.
# 2. Firewall exception: tailscaled drops, via its ts-input chain, every
#    packet with source 100.64.0.0/10 received on an interface other than tailscale0.
#    wg0 IS in this range (100.89.128.0/24): without ACCEPT at the head of INPUT,
#    tower's SYN-ACKs and ICMP are dropped on the VPS side (handshakes OK,
#    Traefik 504 everywhere, 6h40 of outage on 2026-10-23).
#
# Note: same logic as /usr/local/bin/wg0-guard.sh + wg0-guard.{service,timer}
# placed imperatively on the VPS the evening of the outage. When this module is
# deployed, remove the imperative installation:
#   systemctl disable --now wg0-guard.timer && rm /etc/systemd/system/wg0-guard.* /usr/local/bin/wg0-guard.sh
{ pkgs, lib, ... }:
{
  systemd.services.wg0-runtime-guard = {
    description = "Repairs the wg0 runtime guard (address + tailscale firewall exception)";
    after = [ "network-online.target" "tailscaled.service" "firewall.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "wg0-runtime-guard";
        runtimeInputs = [ pkgs.coreutils pkgs.iproute2 pkgs.iptables pkgs.gnugrep ];
        text = ''
          if ip link show wg0 >/dev/null 2>&1; then
            if ! ip -4 addr show wg0 | grep -q 'inet 100\.89\.128\.1/'; then
              echo "wg0-runtime-guard: missing address, adding 100.89.128.1/24" >&2
              ip addr add 100.89.128.1/24 dev wg0 || echo "wg0-runtime-guard: addr add failed, continuing" >&2
            fi
            if ! ip route show dev wg0 | grep -q '100\.89\.128\.0/24'; then
              echo "wg0-runtime-guard: missing route, adding 100.89.128.0/24" >&2
              ip route add 100.89.128.0/24 dev wg0 || echo "wg0-runtime-guard: route add failed, continuing" >&2
            fi
          fi
          if ! iptables -C INPUT -i wg0 -s 100.89.128.0/24 -j ACCEPT 2>/dev/null; then
            echo "wg0-runtime-guard: firewall exception absent, inserting" >&2
            iptables -I INPUT 1 -i wg0 -s 100.89.128.0/24 -j ACCEPT || echo "wg0-runtime-guard: rule insertion failed" >&2
          fi
        '';
      });
    };
  };

  systemd.timers.wg0-runtime-guard = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };
}
