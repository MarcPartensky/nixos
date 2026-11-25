# Glances in web mode: a "web htop" to inspect tower's tasks.
#
# The nixpkgs module (services.glances) runs `glances --webserver` under
# DynamicUser with a hardened systemd sandbox. The UI (sortable process table,
# CPU/RAM/network graphs, REST API) listens on 0.0.0.0:61208. The firewall
# stays CLOSED (openFirewall = false by default): remote access goes
# only through the Pangolin resource `proc.marcpartensky.com` (newt hits the
# loopback, SSO enabled on the Pangolin side), like kasm/vnc.
#
# Health paths for newt: `/` and `/api/4/status` return 200.
{ ... }:
{
  services.glances.enable = true;

  # Default extraArgs: [ "--webserver" ]. The default refresh
  # (1 s) is enough for the human eye; use services.glances.extraArgs
  # to add -t (interval) or -B (bind) the day you need it.
}
