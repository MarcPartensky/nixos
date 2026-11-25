# Ensures that wg0, the interface carrying the newt clients, really has its address
# on every gerbil start.
#
# Why: gerbil only applies the wg0 address if it creates the interface
# itself. If a residual wg0 exists when it starts, it
# reuses it as is (log "WireGuard interface wg0 already exists") and
# the interface stays without an address, hence without a route for the subnet of
# newt clients (100.89.128.0/24). The WireGuard handshakes keep
# working, they do not depend on addressing, but no byte of
# data flows anymore: Traefik no longer reaches any target (504 on all
# domains served by the tunnel) and newt declares the connection dead every
# ~3 minutes.
#
# The upstream nixpkgs workaround (gerbil ExecStartPost, script
# gerbil-wg0-fix-script) does exactly this cleanup, but only once per
# machine: it is guarded by the marker /var/lib/pangolin/config/wg0, present
# since April, hence inert since. Here the check is replayed on every
# start, without a marker or a unit restart.
{ pkgs, lib, ... }: {
  systemd.services.gerbil.serviceConfig.ExecStartPre = lib.mkForce (lib.getExe (pkgs.writeShellApplication {
    name = "gerbil-wg0-drop-unaddressed";
    runtimeInputs = [ pkgs.coreutils pkgs.iproute2 ];
    text = ''
      if ip link show wg0 >/dev/null 2>&1 && ! ip -4 addr show wg0 | grep -q 'inet '; then
        echo "wg0 present without address: removing before gerbil start" >&2
        ip link delete wg0
      fi
    '';
  }));
}
