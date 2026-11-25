# services/terminal/default.nix
# REAL web terminal on terminal.marcpartensky.com (ttyd).
#
# Until now this domain served the Hermes admin panel
# (services/hermes-dashboard), whose "terminal page" is only a tab of
# that UI: so it was not a terminal. Here the URL serves ONLY the terminal.
#
# Tech: ttyd (MIT, C/libwebsockets + xterm.js), already in nixpkgs with its
# NixOS module `services.ttyd`. Nothing to package, a single binary, a real PTY
# per client, websockets handled by the module.
#
# Chain: Pangolin (terminal.marcpartensky.com, SSO)
#          -> newt (site tower)
#          -> 127.0.0.1:9122 (ttyd, --interface lo: loopback only)
#
# User: `marc`, not `hermes`. It is marc's terminal (his home, his
# tools, his zellij), protected by the same Pangolin SSO as the already
# exposed noVNC/Kasm desktop. To get the agent's shell instead (the one
# that has the NOPASSWD sudo nixos-rebuild and the ACL on ~/git/nixos), change
# `user` and the PATH of `terminalSession` below.
#
# Persistence: the ttyd entrypoint attaches a named zellij session instead of
# launching a bare bash, so closing the tab (or losing the mobile network) does not kill
# the work in progress: you re-attach to the same session. Fallback to a
# login shell if zellij is not usable (no XDG_RUNTIME_DIR).
#
# NEVER open 9122 on the firewall: ttyd is an interactive shell.
{
  config,
  lib,
  pkgs,
  ...
}: let
  port = 9122;
  # Shared zellij session: all clients (tabs, phone) land
  # in the same session. Changing it = a new blank terminal.
  zellijSession = "web";

  # ttyd entrypoint: persistent zellij, otherwise a login shell.
  terminalSession = pkgs.writeShellApplication {
    name = "terminal-session";
    runtimeInputs = [
      pkgs.zellij
      pkgs.bashInteractive
      pkgs.coreutils
    ];
    text = ''
      # marc's home-manager profile is not in the default PATH of
      # systemd units: without it, zellij (and its tools) cannot be found.
      #
      # /run/wrappers/bin BEFORE the system profile, no exception: the profile's
      # sudo (/run/current-system/sw/bin/sudo) is NOT setuid, it exits with
      # "must be owned by uid 0 and have the setuid bit set". The zellij server
      # keeps this environment for ALL panes attached to it (even
      # from marc's terminal), so the order set here applies to the whole
      # session and to the wrappers (sudo, mount, ping, fusermount).
      export PATH="/run/wrappers/bin:/run/current-system/sw/bin:/home/marc/.nix-profile/bin''${PATH:+:$PATH}"

      # zellij (its session server) requires a writable XDG_RUNTIME_DIR,
      # which belongs to marc's session. users.users.marc.linger = true is
      # set in profiles/tower (KasmVNC), so /run/user/1000 exists even without
      # a graphical session; if that is not the case we fall back to bash.
      # (two statements to satisfy shellcheck SC2155, cf. writeShellApplication)
      runtime_dir="/run/user/$(id -u)"
      if [ -z "''${XDG_RUNTIME_DIR:-}" ] && [ -d "$runtime_dir" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
      fi

      if [ -n "''${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        exec zellij attach --create ${zellijSession}
      fi

      echo "zellij unavailable (XDG_RUNTIME_DIR absent): simple login shell" >&2
      exec bash -l
    '';
  };
in {
  services.ttyd = {
    enable = true;
    port = port;
    # Loopback only: measurement of 11/11/2026, `ttyd --interface lo` binds
    # 127.0.0.1:9122 (and not 0.0.0.0). Only newt reaches the port.
    interface = "lo";
    user = "marc";
    # -W: the client writes into the PTY (that is the whole point of a terminal).
    writeable = true;
    maxClients = 4;
    entrypoint = [ (lib.getExe terminalSession)];
    clientOptions = {
      fontSize = "14";
      # marc's default theme (Catppuccin Mocha), Lavender accent.
      theme = builtins.toJSON {
        background = "#1e1e2e";
        foreground = "#cdd6f4";
        cursor = "#b4befe";
        cursorAccent = "#1e1e2e";
        selectionBackground = "#585b70";
        black = "#45475a";
        red = "#f38ba8";
        green = "#a6e3a1";
        yellow = "#f9e2af";
        blue = "#89b4fa";
        magenta = "#cba6f7";
        cyan = "#94e2d5";
        white = "#bac2de";
        brightBlack = "#585b70";
        brightRed = "#f38ba8";
        brightGreen = "#a6e3a1";
        brightYellow = "#f9e2af";
        brightBlue = "#89b4fa";
        brightMagenta = "#cba6f7";
        brightCyan = "#94e2d5";
        brightWhite = "#a6adc8";
      };
    };
    # `checkOrigin` stays disabled (default): when enabled, ttyd compares the
    # Origin header with the received Host, and Pangolin does not guarantee
    # forwarding the public Host (the dashboard resource goes through a local nginx
    # precisely to rewrite the Host). The gate, here, is the Pangolin SSO.
  };

  # The unit runs in marc's home with a full PATH: the shell obtained
  # is the one he would have over SSH (git, just, nixos-rebuild...).
  systemd.services.ttyd = {
    environment.HOME = "/home/marc";
    serviceConfig.WorkingDirectory = "/home/marc";
    # A rebuild must not cut the current session (same choice as
    # services/hermes-webui): the config applies at the next start.
    restartIfChanged = false;
  };

  # Public exposure: terminal.marcpartensky.com -> 127.0.0.1:9122, Pangolin
  # SSO (Zitadel) like the other UIs.
  #
  # Key `hermes-terminal` INTENTIONAL: it is the niceId (identifier) of the
  # Pangolin resource that ALREADY carries terminal.marcpartensky.com (resourceId 28,
  # target 9121 = Hermes admin panel). A blueprint matches by key and NEVER
  # deletes a missing entry: renaming the key would have created a
  # second resource on the same domain (conflict) while leaving the old one
  # orphaned on that domain. Keeping the key therefore brings the resource up to
  # date (name + target 9122) and the admin panel moves to a new resource,
  # `hermes-dashboard` in services/hermes-dashboard (verified on 11/11/2026:
  # resourceId 28, niceId hermes-terminal, skipToIdpId null).
  #
  # NB: `auth.sso-enabled` gates the resource, but the blueprint has no
  # field to go directly to the IdP: `resources.skipToIdpId = 1` is set
  # in the Pangolin DB for the other resources (navidrome, aonsoku...), otherwise
  # the proxy's internal login page shows before Zitadel. To re-set if the
  # resource is recreated (uuid changes).
  services.newt.blueprint.proxy-resources.hermes-terminal = {
    name = "terminal";
    protocol = "http";
    full-domain = "terminal.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        # ttyd answers 200 text/html on "/" (measurement of 11/11/2026).
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
          path = "/";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # Safeguard: 9122 is an interactive shell.
  assertions = [
    {
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "terminal: port ${toString port} (ttyd = shell) must not be open on the firewall.";
    }
  ];
}
