# n8n: workflow automation (web UI), loopback 127.0.0.1:5678.
#
# Reuse of tower's historical instance: the Pangolin resource
# `n8n.marcpartensky.com` (SSO active, default healthcheck `/healthz`) already
# targets 127.0.0.1:5678; only the service was missing. The existing data
# lives in /var/lib/n8n (default value of the module's N8N_USER_FOLDER,
# reused as is); it comes from a container (unknown uid), hence
# the chown -R to the service's dynamic user on first start.
#
# The firewall stays closed (openFirewall default false): access via newt/Pangolin.
{ pkgs, ... }:
{
  services.n8n.enable = true;

  # Data inherited from a container: re-own it to the service before start
  # ("+" = runs as root before the drop to DynamicUser).
  systemd.services.n8n.serviceConfig.ExecStartPre = [
    "+${pkgs.coreutils}/bin/chown -R n8n:n8n /var/lib/n8n"
  ];
}
