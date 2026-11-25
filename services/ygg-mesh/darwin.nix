# services/ygg-mesh/darwin.nix
#
# macOS side (nix-darwin) of the ygg-mesh network: package + Tor client + daemon.
# Imported by profiles/macos/configuration.nix. The NixOS module of this network
# lives in services/ygg-mesh/default.nix; the Yggdrasil config file
# (/etc/yggdrasil.conf) is described in its header and is NOT set by the
# nix store (it contains the shared password).
#
# What this module installs:
#   - yggdrasil + tor (nixpkgs packages, 0.5.13 / 0.4.9 like the Linux nodes);
#   - tor as a SOCKS client (127.0.0.1:9050): exit towards the mesh onions and
#     the nodes when the Mac is outside the LAN;
#   - the yggdrasil daemon that reads /etc/yggdrasil.conf (to create once,
#     root:wheel 0600). On the LAN, the direct multicast link takes over.
#
# The torrc contains no secret (just ports): it can live in the
# store, unlike /etc/yggdrasil.conf.
#
# Minimal config of /etc/yggdrasil.conf (see the NixOS module header for
# up-to-date values): Listen = [], Peers = the socks://...@127.0.0.1:9050 URIs
# to the node onions, MulticastInterfaces { Beacon=false; Listen=true;
# Port=12346; Password=<password> }, AllowedPublicKeys = the nodes' keys.

{ pkgs, lib, ... }:

let
  torrc = pkgs.writeText "ygg-mesh-torrc" ''
    SocksPort 127.0.0.1:9050 IsolateDestAddr IsolateSOCKSAuth
    AvoidDiskWrites 1
    SafeLogging 1
  '';
in
{
  environment.systemPackages = [ pkgs.yggdrasil pkgs.tor ];

  # System daemons (root): yggdrasil creates a utun interface, tor opens the
  # SOCKS on loopback. nix-darwin waits for the store mount at boot before
  # launching the command (wait4path).
  launchd.daemons.ygg-mesh-tor = {
    command = "${pkgs.tor}/bin/tor -f ${torrc}";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/var/log/ygg-mesh-tor.log";
      StandardErrorPath = "/var/log/ygg-mesh-tor.log";
    };
  };

  launchd.daemons.yggdrasil = {
    command = "${pkgs.yggdrasil}/bin/yggdrasil -useconffile /etc/yggdrasil.conf";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/var/log/yggdrasil.log";
      StandardErrorPath = "/var/log/yggdrasil.log";
    };
  };
}
