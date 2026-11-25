# One SSH alias per device of the tailnet, all pointing at the device's
# MagicDNS name (<node>.ts.marcpartensky.com, served by tailscaled): the alias
# follows a renamed node or a changed mesh address, and works at home, on a
# phone hotspot or behind another network (direct path, DERP relay otherwise).
# Requires MagicDNS on the client: without it the public wildcard
# *.marcpartensky.com would send these names to the VPS.
# Shared by every home profile (marc, root, deck, mac); the hermes agent keeps
# the same list in its own ~/.ssh/config (tower == tower.ts.marcpartensky.com).
#
#   tower -> tower.ts...    deck -> deck.ts...     laptop -> laptop.ts...
#   mac   -> mac.ts...      phone -> phone.ts...   vps    -> vps.ts...
#
# The non-mesh aliases (LAN, public bootstrap, reverse tunnels) stay at the
# bottom as fallbacks.
{...}: {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        IdentityFile = "~/.ssh/id_ed25519";
        ServerAliveInterval = 60;
        ForwardAgent = true;
        # The tailnet aliases are MagicDNS names, so their host key is a new
        # known_hosts entry (the mesh IPs were already there). accept-new pins
        # an unknown host on first use but still refuses a CHANGED key, so an
        # alias works on a fresh machine without weakening MITM protection.
        StrictHostKeyChecking = "accept-new";
      };

      # --- Tailnet devices --------------------------------------------------
      "tower" = {
        HostName = "tower.ts.marcpartensky.com";
        User = "marc";
        Port = 22;
      };
      "deck" = {
        HostName = "deck.ts.marcpartensky.com";
        User = "marc";
        Port = 22;
      };
      "laptop" = {
        HostName = "laptop.ts.marcpartensky.com";
        User = "marc";
        Port = 22;
      };
      "mac" = {
        HostName = "mac.ts.marcpartensky.com";
        User = "marc";
        Port = 22;
      };
      # Nix-on-Droid sshd, published on the mesh by the phone itself.
      "phone" = {
        HostName = "phone.ts.marcpartensky.com";
        User = "nix-on-droid";
        Port = 8023;
      };
      # Controller, DERP, exit node and AdGuard of the mesh.
      "vps" = {
        HostName = "vps.ts.marcpartensky.com";
        User = "root";
        Port = 22;
      };
      # Hermes agent account on tower: same machine, different account.
      "hermes" = {
        HostName = "tower.ts.marcpartensky.com";
        User = "hermes";
        Port = 22;
      };

      # --- Bootstrap and fallbacks ------------------------------------------
      # Public entry point of the VPS: still works when tailscaled is down.
      "rack" = {
        HostName = "marcpartensky.com";
        User = "root";
        Port = 22;
      };
      # tower on the home LAN, if the mesh is down.
      "towerlocal" = {
        HostName = "192.168.1.44";
        User = "marc";
        Port = 22;
      };
      # Mac on the home LAN (DHCP, address may change).
      "maclan" = {
        HostName = "192.168.1.48";
        User = "marc";
      };
      # Mac through the reverse autossh tunnel of its launchd agent
      # (modules/home-mac/autossh), published by rack on 2223.
      "mactun" = {
        HostName = "localhost";
        User = "marc";
        Port = 2223;
        ProxyJump = "rack";
      };
      # Phone through its own reverse tunnel (rack:2224 -> phone:8023).
      "phonetun" = {
        HostName = "localhost";
        User = "nix-on-droid";
        Port = 2224;
        ProxyJump = "rack";
      };
      # wstunnel entry point of the VPS (services/wstunnel), for networks that
      # only let 443/WSS out.
      "tunnel" = {
        HostName = "localhost";
        User = "marc";
        Port = 2222;
        ProxyJump = "rack";
      };
    };
  };
}
