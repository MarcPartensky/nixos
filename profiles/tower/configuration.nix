{
  lib,
  pkgs,
  inputs,
  config,
  ...
}: let
  # WireGuard client to the VPS (see the WIREGUARD CLIENT section at the bottom).
  wgClientEnable = true;
in {

  # tower routes the phone's traffic to the internet (exit node) and announces the LAN
  # at home, to reproduce the behavior of the WireGuard tunnel. The output of the
  # VPS is still preferable for throughput (cf. meshTailscale on anywhere).
  meshTailscale = {
    advertiseExitNode = true;
    advertiseRoutes = [ "192.168.1.0/24" ];
  };

  # Offload builds to the laptop and the deck. Tower is the interactive machine:
  # a compiler must never run here. Two levels, both declarative:
  #
  #  - `nix.buildMachines` (below): what the DAEMON uses, so any
  #    `nix build` (Justfile, scripts, nix-shell, nixos-rebuild without --builders).
  #    Both machines are there: Nix spreads the derivations over those that have
  #    a free slot.
  #  - nix-builders-pick (modules/nixos/nixos-rebuild-gated/builders-pick.sh) :
  #    probes laptop and deck (headroom = nproc - load1, available RAM) and yields
  #    the `--builders` value. The nixos-rebuild-gated wrapper injects it on each
  #    switch and the Justfile `build` uses it: the saturated machine is excluded,
  #    jobs go to the least loaded one.
  #
  # The key /var/lib/hermes/.ssh/nix-builder is the hermes@tower -> builders pair.
  # The daemon (root) does NOT receive sshKey via ssh: the identity is therefore set in
  # root's ssh config (users/root/home.nix). On the builders side it must be
  # authorized DECLARATIVELY (services/hermes/default.nix for the laptop,
  # profiles/deck for the deck): in ~/.ssh/authorized_keys sshd StrictModes
  # ignored it when the home is group-writable (laptop in 2770 -> Permission
  # denied silently, observed on 2026-11-25).
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = "laptop";
      system = "x86_64-linux";
      maxJobs = 4;
      protocol = "ssh-ng";
      sshUser = "hermes";
      sshKey = "/var/lib/hermes/.ssh/nix-builder";
      supportedFeatures = [ "big-parallel" "benchmark" "nixos-test" ];
    }
    {
      # Deck: 8 cores, but it is marc's console (jovian/steam) -> 3 jobs.
      hostName = "deck";
      system = "x86_64-linux";
      maxJobs = 3;
      protocol = "ssh-ng";
      sshUser = "hermes";
      sshKey = "/var/lib/hermes/.ssh/nix-builder";
      supportedFeatures = [ "big-parallel" "benchmark" "nixos-test" ];
    }
  ];

  # AdGuard canNOT listen on 0.0.0.0 (aardvark-dns of the podman networks
  # already holds port 53 of the 10.88/10.89 gateways): we give the mesh address
  # in addition to loopback, otherwise the resolver stays dead for the whole tailnet.
  services.dnsFilter.bindHosts = [ "127.0.0.1" "100.64.0.3" ];
  # Blocklists and short-name rewrites live in services/adguard/tailnet.nix,
  # shared with the VPS instance so both resolvers answer identically (the
  # client races them and keeps the first answer).

  imports = [
    # Shared tailnet DNS policy (blocklists + short names) for this AdGuard
    # instance and the one on the VPS.
    ../../services/adguard/tailnet.nix
    # Single MCP server: one process for all the home servers, on
    # a loopback URL. Measurement: 8 real servers, 90 tools, 85 MB of RSS,
    # versus 133 processes and 1.7 GB with one process per session. Hermes
    # sessions can switch to it by pointing mcpServers at the URL; as long
    # as they do not, the old stdio wiring stays in place and nothing
    # breaks. See modules/nixos/mcp-host and mcp/main.py.
    ../../modules/nixos/mcp-host
    # Single Rust MCP host: owns the stdio servers once, one HTTP endpoint.
    # enable = false by default; takeover flips Hermes onto its URL.
    ../../modules/nixos/mcp-host-rs
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
    ../../modules/nixos/herdr
    # Stalwart MCP (JMAP to the VPS): tower only, hermes runs there.
    ../../services/stalwart-mcp
    # Discord bot (bridge to the Hermes API server): tower only, its
    # secret lives in secrets/tower.yml. Moved out of services/default.nix, where it
    # broke the build of any host importing ./services without this secret.
    ../../services/discord-bot
    # ../../services/gotify  # MOVED to anywhere (2026-11-20): the Gotify
    # server, its database and its Pangolin resource now live on the VPS.
    # Only the CONSUMERS remain here (gotify-matrix bridge below,
    # mesh-dashboard, gateway hook) that talk to
    # https://gotify.marcpartensky.com with their application tokens.
    # The bridge was imported ONLY by the services/default.nix aggregator, which this
    # profile does not import: the 21/11 00:21 generation therefore lost it (units
    # gotify-matrix-relay / gotify-pont-provision gone). Explicit import.
    ../../services/gotify-matrix
    # Hermes voice bridge (8999) + Pangolin resource voice.marcpartensky.com.
    ../../services/hermes-voice
    ../../services/jupyterhub
    ../../services/monero-miner
    # Local Nix binary cache (atticd, disk storage): avoids recompiling
    # the home packages after a GC or a flake update, and feeds the cache
    # via the nix daemon's post-build-hook.
    ../../services/attic
    # Glances web (htop web, 61208) exposed at proc.marcpartensky.com.
    ../../services/glances
    # Immich (immich.marcpartensky.com, 2283): photos/videos interface of
    # the /home/marc/media/photos tree as a read-only external library.
    ../../services/immich
    # single-node k3s, WITHOUT Rancher (2026-11-20): the Rancher chart and its
    # Pangolin resource are behind the `withRancher = false` flag in
    # services/k3s/default.nix. Measurement before removal: 1.5 core continuously
    # for 10 control-plane pods that served no workload, plus
    # a kine datastore that failed to compact every 5 min. k3s stays
    # in place for the pods API; the datastore was recreated from scratch.
    ../../services/k3s
    # Internal tailnet TLS proxy: *.intra.marcpartensky.com on 9443,
    # Let's Encrypt wildcard certificate via DNS-01 (see the module).
    ../../services/traefik-intra
    # PhotoPrism was REMOVED (marc's choice, 2026-11-14): Immich stays.
    # The services/photoprism module still exists but is no longer imported;
    # its storage /var/lib/photoprism can be deleted.
    # Comparison of homelab dashboards (homer, homepage, glance, homarr):
    # each candidate on loopback, relayed by newt via a Pangolin
    # resource with SSO. See services/dashboards.
    ../../services/dashboards
    # Octo (octo.marcpartensky.com): OpenSubsonic proxy in front of Navidrome that
    # searches outside the library, plays an absent track as a YouTube preview and
    # downloads it on a core. Two podman containers. See services/octo.
    ../../services/octo
    # ygg-mesh private network (Yggdrasil via Tor + direct LAN link), members:
    # tower, anywhere, deck. See services/ygg-mesh/default.nix.
    ../../services/ygg-mesh
    # headscale mesh: tailscale node (controller on the VPS anywhere, cf
    # services/headscale and services/tailscale).
    ../../services/tailscale
    # Dashboard of the tailnet nodes (mesh.marcpartensky.com, Pangolin SSO;
    # http://100.64.0.3:9140 from the tailnet). Reads `tailscale status --json`.
    ../../services/mesh-dashboard
    # Health of SSH aliases and reverse tunnels (tunnel.marcpartensky.com,
    # Pangolin SSO): probes every 60 s from tower, page served on
    # loopback on 9144 and published by newt. See services/tunnel-health.
    ../../services/tunnel-health
    # marc's presence (Rust): Mac / phone / tower, location (home, office,
    # outside), inferred sleep, usage forecast and CPU RESERVATION (the
    # background job governor no longer loosens the caps when marc will
    # soon need the machine). Contract unchanged: devices.json.
    ../../services/presence
    # LLM usage dashboard (usage.marcpartensky.com, without Pangolin SSO): balance and
    # OpenRouter spend per model / key / day, plus the direct balances
    # (Moonshot) and subscriptions outside OpenRouter. Reads /api/v1/analytics.
    ../../services/usage-dashboard
    # Spending tracking page (finance.marcpartensky.com, Pangolin SSO):
    # reads /var/lib/hermes/workspace/finance/dashboard.json, written every morning
    # by the cron "Daily finances recap" (Wise + Chase via SimpleFIN).
    ../../services/finance-dashboard
    # UCPA stays finder (ucpa.marcpartensky.com, Pangolin SSO):
    # all dated ski/snowboard sessions with price and spots, filtering
    # on the browser side (package, age, duration, price). Reuses the client of the
    # MCP server mcp/modules/ucpa.py.
    ../../services/ucpa-app
    # Per-process CPU telemetry (atop 10 s + atop-peaks): tower only,
    # this is where builds and Hermes sessions compete for the CPU.
    ../../services/atop
    # Windmill: fleet server (UI/API + Postgres database `windmill`).
    # The workers run on deck / anywhere and take the jobs from the
    # same database via the tailnet. tower does NOT host a worker: it stays free.
    ../../services/windmill
    # Personal F-Droid repo (fdroid.marcpartensky.com): the release APKs of
    # marc's apps, addable in Droidify. See services/fdroid-repo.
    ../../services/fdroid-repo
    # 3D atlas of the infra (atlas.marcpartensky.com): separate project under
    # /var/lib/hermes/workspace/infra-atlas, imported by the `infra-atlas` INPUT
    # of the flake (locked in flake.lock), not by a builtins.getFlake:
    # the getFlake made tower's evaluation impure. Bump of the atlas project
    # = `nix flake update infra-atlas`.
    # Catch-up of critical units not started after a boot: systemd never
    # restarts a unit whose dependency failed (see the header of the
    # module, measurement of 2026-11-17: 5 h of matrix outage after a postgres
    # recovery postgres).
    ../../services/boot-recovery
    # Typing practice (typer.marcpartensky.com): static front-end and
    # race rooms /ws served by the same socket. The module and the package
    # come from the typer flake (input above, vendored under projects/typer):
    # Rust binaries typer-server + terminal client typer-race, the Python of
    # services/typer is no longer deployed (kept under projects/typer/legacy/).
    inputs.typer.nixosModules.default
    inputs.infra-atlas.nixosModules.default
    # mnemo.marcpartensky.com: retention engine (conversation scoring,
    # explanation sheets, podcast and typing sources). Standalone flake
    # vendored under projects/mnemo; k3s pod + dedicated database come from the module.
    inputs.mnemo.nixosModules.default
  ];

  # Purge of Alexandre's guest agent, removed from the flake on 2026-11-24 (own OS
  # user, own HERMES_HOME, Pangolin domain, Zitadel project). This one-shot
  # deletes the old home, which contains its state.db (conversations, memory,
  # sessions): without it the folder survives the user deletion.
  # ConditionPathExists makes it inert once the folder is erased, so it
  # costs nothing afterwards (and it can be removed from the flake next time).
  systemd.services."alexandre-home-purge" = {
    description = "Purge /var/lib/alexandre (guest agent Hermes retire)";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/var/lib/alexandre";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/rm -rf /var/lib/alexandre";
    };
  };

  # Boot safety net: restarts matrix / immich / attic if they are
  # not active within 2 h after boot, 6 attempts max per unit.
  services.bootRecovery.enable = true;

  # pqbox encrypted backups in three tiers (daily core, weekly
  # volume, manually pruned). Public key in services/backup-pqbox,
  # private key sealed at marc's only. Cf. the module for details.
  # Since 2026-11-14 the PRODUCER is the laptop (03:10): here we are
  # only the safety net, we run at 05:00 and do nothing if an archive
  # less than 4 h old already exists (laptop on at night, or not).
  services.backup-pqbox = {
    enable = true;
    coeurAt = "*-*-* 05:00:00";
    skipIfFresh = 4;
  };

  # Interactive 3D atlas of the infra (cluster, network, agent, MCP, tasks, auth,
  # backups): atlas.marcpartensky.com behind the Pangolin SSO, loopback port.
  services.infraAtlas.enable = true;

  # Spending tracking page (finance.marcpartensky.com).
  services.financeDashboard.enable = true;

  # Typing practice (typer.marcpartensky.com): Rust server typer-server
  # (static + rooms /ws), terminal client typer-race. The solo
  # terminal version stays ttyper (users/marc/packages.nix).
  services.typer.enable = true;

  # mnemo (mnemo.marcpartensky.com): retention engine. Runs as a k3s POD
  # (hostNetwork, 127.0.0.1:9152) to stay reachable by Pangolin like the
  # other host services, with its own Postgres database. The OCI image is
  # built on the laptop (`nix build .#image`) and dropped into
  # /var/lib/hermes/mnemo/mnemo-oci.tar; the module imports it into containerd.
  # Nothing compiles Rust on tower.
  services.mnemo.enable = true;

  # marc's presence (Rust): devices, location, forecast, CPU reservation.
  services.presence.enable = true;

  # UCPA stays finder (ucpa.marcpartensky.com): dated sessions,
  # price and spots, package/age/duration/price filters on the browser side.
  services.ucpaApp.enable = true;

  services.windmillFleet = {
    enable = true;
    role = "server";
    expose = true;
    # No Windmill login: the application OIDC is an Enterprise feature in
    # CE (stubs), and Pangolin already authenticates via Zitadel upstream.
    noAuth = true;
    baseUrl = "https://windmill.marcpartensky.com";
  };

  # Hermes sessions launched by marc (herdr panes, shared HERMES_HOME, cf
  # users/marc/home.nix) write into /var/lib/hermes/.hermes. The hermes group
  # (users.nix) plus the g+rw chmods of the hermes module cover the existing
  # setup; these ACLs guarantee traversal of /var/lib/hermes (2770) and that
  # files created by marc stay readable by the service. Pattern taken from
  # services/amazon-mcp.
  #
  # 2026-11-25: group WRITE on the .hermes directory itself must stay disabled.
  # hermes-agent 514e2cbd refuses a group-writable home for its control socket
  # (home_mode_unsafe, hermes_cli/gateway_runtime_discovery.py): with the mask
  # at rwx, EVERY agent-mode cron run failed with GatewayUnavailableError
  # (unsafe_control_permissions) - 55 failures on 24/11, all the watches
  # (tunnel, inbox, cpu) were dead. The home mask is therefore r-x (mode 0750):
  # marc keeps read + traversal, and the default entries (d:u:marc:rwx) still
  # give rwx on files created afterwards (plugins/, sessions/...). Verified on
  # 25/11: marc writes nothing at the first level of .hermes (only
  # plugins/herdr-agent-state belongs to him).
  #
  # The mode needs three layers because two other actors keep rewriting it:
  #   - the hermes-agent-setup activation snippet chmods 2770 on the home at
  #     every activation, and a chmod on an ACL-carrying directory resets the
  #     mask to rwx: covered by the activationScripts step below, ordered
  #     after that snippet;
  #   - every credential save re-chmods the home to 0700 at RUNTIME:
  #     secure_parent_dir() in hermes_constants.py (auth.py _save_private_json
  #     -> auth.json, which lives at the home root) has no managed-install
  #     carve-out, unlike apply_secure_dir_policy(). Observed 2026-11-25
  #     02:06:59: auth save, mode 750 -> 700, marc locked out while the gateway
  #     kept running. Root fix: the hermes-agent package patch declared in
  #     services/hermes (hermes-agent-managed-home.py). Until that package is
  #     deployed, the hermes cron job `home-mode-guard` re-applies the mode
  #     within two minutes.
  #
  # Do NOT go back to a `Match User hermes` + `StrictModes no` block to
  # bypass StrictModes (that was the state of 2026-11-14): StrictModes is not
  # an allowed directive in a Match block, sshd then rejects ALL its
  # configuration and the system build fails, not just the access.
  # There is nothing to bypass anyway: the authorized keys are
  # declarative, sshd reads them in /etc/ssh/authorized_keys.d/hermes and does
  # not look at the home. Verification done: `ssh hermes@127.0.0.1` with
  # a public key answers with the home in 2770.
  systemd.tmpfiles.rules = [
    "d /var/lib/hermes/.hermes 0750 hermes hermes -"
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "a /var/lib/hermes/.hermes - - - - u:marc:r-x,d:u:marc:rwx,m::r-x,d:m::rwx"
    "a /var/lib/hermes/.hermes/plugins - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
  ];

  # Do not trust the tmpfiles order alone: the activation snippet
  # hermes-agent-setup (hermes-agent module) redoes a `chmod 2770` on the home
  # on EVERY activation, and on a folder carrying an ACL a chmod resets the
  # mask to rwx - home_mode_unsafe falls back into the trap even when the rule
  # `a` above is correct (observed on 2026-11-25: mode back to 2770
  # after switch, all the agent cron jobs in GatewayUnavailableError). We
  # therefore reapply mode + r-x mask AFTER this snippet. The same pair is what
  # the cron job `home-mode-guard` replays at runtime, because every credential
  # save re-chmods the home to 0700 (secure_parent_dir, no managed carve-out)
  # until the patched hermes-agent package of services/hermes is deployed.
  # Simulation verified on 25/11: chmod 2770 -> discover inaccessible ;
  # setfacl -m m::r-x -> discover ready.
  system.activationScripts."hermes-home-acl-mask" =
    lib.stringAfter [ "hermes-agent-setup" ] ''
      chmod 0750 /var/lib/hermes/.hermes
      ${pkgs.acl}/bin/setfacl -m u:marc:r-x,d:u:marc:rwx,m::r-x,d:m::rwx /var/lib/hermes/.hermes
    '';

  # systemd journal: without a cap, journald climbs to 10 % of the filesystem,
  # i.e. ~18 GB on the root dataset (186 GB). Same fix as
  # profiles/anywhere (500M): we keep enough to diagnose a week, not
  # enough to fill a pool already at 96 %. The rest of /var/log (atop, 3 days
  # wanted) is not concerned.
  services.journald.extraConfig = "SystemMaxUse=1G";

  # Cap on the ZFS ARC cache. Without it, zfs_arc_max is 0 (default) and the
  # cache climbs to ~61 GB out of 62, which pushes the services and builds
  # into swap: eval measurement 236 s under pressure versus 90 s at rest.
  # This parameter applies at module load, so at boot.
  boot.kernelParams = ["panic=10" "zfs.zfs_arc_max=17179869184"];

  # Hot application, without reboot: a no-op at boot (the value is already
  # set by the kernel parameter) and immediate effect at the first switch.
  systemd.services.zfs-arc-cap = {
    description = "Caps the ZFS ARC cache at 16 GB";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "zfs-arc-cap" ''
        want=17179869184
        cur=$(cat /sys/module/zfs/parameters/zfs_arc_max)
        if [ "$cur" != "$want" ]; then
          echo "$want" > /sys/module/zfs/parameters/zfs_arc_max || true
        fi
        echo "zfs_arc_max=$(cat /sys/module/zfs/parameters/zfs_arc_max)"
      ''}";
    };
  };

  # Compressed swap in RAM: 25% of memory, i.e. ~15 GB, to prevent the
  # slightest pressure from going to the NVMe. Replaces the disk as the first
  # swap level.
  zramSwap = {
    enable = true;
    memoryPercent = 25;
    algorithm = "zstd";
    # Priority of the compressed swap, not just its activation. nixpkgs default
    # = 5, versus disk swap at 100: the kernel ALWAYS takes the highest,
    # so the NVMe was consumed first and zram was never used
    # (measurement 2026-11-14: 13.5 GB out of 16 GB of disk swap used, 120 KB out of
    # 15.6 GB of zram). Anonymous pages now compress in RAM
    # before touching the disk, which removes the freezes of several
    # tens of seconds of the desktop backend and sshd.
    priority = 110;
  };

  # With a capped cache and zram, no point in pushing anonymous pages
  # out at 60%: we keep them in RAM.
  boot.kernel.sysctl."vm.swappiness" = 10;
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  boot.kernelModules = ["vkms"];
  boot.initrd.secrets."/etc/secrets/zfs-root.key" = "/etc/secrets/zfs-root.key";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      2022
      8083 # Pangolin / Apps
      8050
      5432 # PostgreSQL
      6080 # noVNC (client VNC web de la session niri)
      8089 # rustguac
      8443 # KasmVNC
      8200 # Vault
      21115 21116 21118 # RustDesk
      8080 # Dioxus dev (winnie UI)
    ];
  };

  users.users.hermes.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
    # Laptop (hermes@nixos), added on 2026-11-14: it is the one that pulls the
    # pqbox backups over SSH (pg_dump + tar of the Hermes state in streaming).
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTNk2eJYoD87QP/Ajg6iCX/EwYCjVVvoTfTAFqh2qnW hermes@laptop"
  ];

  # Mode and ACL of /var/lib/hermes (sshd StrictModes requirement): see the
  # tmpfiles rules higher up in this file.


  # Authorized keys for marc, in addition to the RSA key of users.nix:
  #   - root@anywhere: SSH access from the VPS via wg1 (10.100.0.3), without depending
  #     on the box's public IP or a forward.
  #   - marc@Air-de-Marc: the Mac, for `ssh tower` which goes through rack
  #     (ProxyJump), wherever it is.
  users.users.marc.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAc2f6U09CWD2yQNcyGz6Pz9EN3aJzvdCvr7FrSSgpwx root@anywhere"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
  ];

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;

  # Gotify moved to anywhere (2026-11-20): all of tower's consumers
  # go through the public URL (Pangolin -> site `rack`) with their
  # application tokens already in place. Without this line the
  # gotify-matrix bridge, mesh-dashboard and the gateway hook would target
  # 127.0.0.1:8070, where nothing listens anymore.
  services.gotifyMatrix.gotifyUrl = "https://gotify.marcpartensky.com";
  # No more Gotify postgres cluster here: the bcrypt alignment of the admin
  # account is done on the VPS, not from tower (which only has an application token).
  services.gotifyMatrix.localDatabase = false;

  # Zitadel admin PAT (encrypted in secrets/zitadel.yml, tower recipient)
  # materialized readable by hermes: used for occasional admin operations
  # via the REST API (OIDC app creation, inspection) as long as the upstream
  # zitadel-mcp is not provisioned (missing zitadel_mcp_env secret).
  sops.secrets."zitadel_mcp_pat" = {
    sopsFile = ../../secrets/zitadel.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  nixpkgs.overlays = [ inputs.ankimcp.overlays.default ];

  # ACME/Let's Encrypt: NO LONGER USED on tower. The public DNS
  # (*.marcpartensky.com) is a wildcard to the VPS 104.129.12.158 (Pangolin),
  # so an http-01 challenge can never reach tower (behind NAT):
  # each ACME vhost ended in "order-renew ... failed", and a contact
  # admin@example.com is refused anyway by Let's Encrypt
  # ("contact email has forbidden domain example.com").
  # The local nginx vhosts below are therefore HTTP loopback, intended to be
  # exposed by a Pangolin/newt resource which carries the TLS itself.
  # If ACME ever comes back here: security.acme.defaults.email = "<real email>";
  # (the old security.acme.email option is deprecated) + acceptTerms = true.

  services.hermes.enableMatrixToken = true;

  # Hardware reservation of the 2 physical cores 6 and 7 (cpu12 to cpu15) to
  # hermes.slice: tower is the only host where the gateway runs permanently,
  # and the isolation only holds on this hardware (16 threads). The other hosts
  # leave the value at null: their CPUs do not exist and an invalid AllowedCPUs
  # would prevent hermes-agent from starting.
  services.hermes.cpuIsolation = "12-15";
  # False from the start: the value of secrets/hermes-discord.yml is a
  # PLACEHOLDER (not a Discord token), and discord.py is not in the sealed
  # venv. With this flag at true, the gateway still enabled the platform
  # (auto-enable as soon as a token exists in .env) then failed with
  # "No adapter available for discord": hence the Discord backend "down" shown
  # permanently in the dashboard. Discord goes through services/discord-bot
  # (marc's bot) -> Hermes API server -> discord-bridge profile: it is THIS
  # path that serves Discord, and it requires no token on the Hermes side.
  # To enable it natively one day (Discord voice): create a SECOND
  # Discord application (a token is not shared between two processes),
  # replace the placeholder in secrets/hermes-discord.yml, set this flag
  # to true and add "discord" to extraDependencyGroups (services/hermes).
  services.hermes.enableDiscordToken = false;

  # ========================================================================
  # RUSTGUAC - Rust Gateway (replaces Guacamole Java)
  # ========================================================================
  services.rustguac = {
    enable = true;
    host = "127.0.0.1";
    port = 8089;
    # guacd has no TLS here: it listens on loopback, and rustguac must speak
    # the same protocol as it (tls = true on both sides, or false on both
    # sides, otherwise the guacamole connection is not established).
    guacd = { host = "127.0.0.1"; port = 4822; tls = false; };
    vault = {
      address = "http://127.0.0.1:8200";
      rootTokenFile = "/run/secrets/vault-rustguac-root-token";
      mountPath = "secret";
      basePath = "rustguac";
    };
    # OIDC DISABLED (2026-09-29): rustguac 1.10.0 expects redirect_uri (not
    # redirect_url), default_role, extra_scopes, and a LITERAL client_secret or
    # the OIDC_CLIENT_SECRET variable (not a file path). Above all, one must
    # first create the OIDC app in Zitadel: client "rustguac", redirect
    # https://guac.marcpartensky.com/auth/callback, then expose the vhost via a
    # Pangolin resource. To enable it:
    #   oidc = { issuerUrl = "https://auth.marcpartensky.com"; clientId = "rustguac";
    #            clientSecretFile = "/run/secrets/rustguac-oidc-client-secret";
    #            redirectUri = "https://guac.marcpartensky.com/auth/callback";
    #            defaultRole = "operator"; extraScopes = [ "groups" ]; };
    # In the meantime, auth is by API key (`rustguac add-admin`).
    oidc = null;
    recording = {
      enable = true;
      path = "/var/lib/rustguac/recordings";
      maxDiskPercent = 80;
    };
    # No rate limiting here: nginx is in front, and rustguac recommends
    # it disabled behind a reverse proxy.
    rateLimit = false;
    trustedProxies = [ "127.0.0.1/32" ];
  };

  # ========================================================================
  # KASMVNC - Remote Plasma 6 desktop (X11)
  # ========================================================================
  services.kasmvnc = {
    enable = true;
    user = "marc";
    # :1 is ALREADY taken by marc's graphical session (Xwayland :1):
    # kasmvncserver then refuses to start ("tower:1 is taken because of
    # /tmp/.X1-lock") and the unit loops until start-limit-hit.
    display = ":20";
    geometry = "1920x1080";
    port = 8443;
    tls = {
      certFile = "/run/secrets/kasmvnc-cert-pem";
      keyFile = "/run/secrets/kasmvnc-key-pem";
    };
    passwordFile = "/home/marc/.kasmpasswd";
    # Plasma 6, NOT in Wayland: KasmVNC is an X server (Xkasmvnc) and cannot
    # host any Wayland DE (kasmtech/KasmVNC#193 - KWin would need patching).
    # startplasma-x11 provides the complete X11 session: taskbar at the bottom
    # (look-and-feel org.hermes.kasm.desktop, konsole + LibreWolf pinned),
    # KRunner, Dolphin, System Settings.
    desktop = "plasma";
    # Pangolin (auth.sso-enabled = true on the kasm resource below) already gates
    # kasm.marcpartensky.com: without this, after the Pangolin SSO, KasmVNC asked again
    # for ITS OWN Basic Auth (password generated by kasmvncpasswd), a double
    # login that even vnc.marcpartensky.com (noVNC) does not impose.
    disableBasicAuth = true;
  };

  # ========================================================================
  # KASMVNC CHROME CDP - Chrome/Chromium with remote debugging for Playwright MCP
  # ========================================================================
  # Goal: SEE live what the automation does. A visible Chromium runs
  # in the Kasm desktop (viewable on 8443 on the LAN and kasm.marcpartensky.com on
  # the Internet), and the MCP attaches to it via --cdp-endpoint http://127.0.0.1:9222:
  # all Playwright actions then happen in THIS window.
  # CDP on loopback only (a reachable CDP port = total control of the
  # browser by anyone who reaches it, so never on the LAN or the Internet).
  services.kasmvnc.chrome-cdp = {
    enable = true;
    browser = "chromium";
    port = 9222;
    bindAddress = "127.0.0.1";
    profileDir = "/home/marc/chrome-cdp-profile";
    extraFlags = [
      "--no-first-run"
      "--no-default-browser-check"
      "--disable-background-networking"
      "--disable-translate"
      "--password-store=basic"
      "--disable-component-extensions-with-background-pages"
      "--disable-features=IsolateOrigins,site-per-process"
    ];
    openFirewall = false;
    exposePublic = false;
  };

  # /home/marc/.kasmpasswd: file in kasmvncpasswd format. Note,
  # kasmvncpasswd has NO -f option and refuses to run without a terminal
  # ("getpassword error: Inappropriate ioctl for device"); it reads the
  # password on stdin when given it twice. The activation therefore runs as
  # root, creates the file once, then hands it to marc. The password lives
  # in secrets/kasmvnc.yml (`sops -d secrets/kasmvnc.yml` to read it).
  # -w -o (write + owner) give marc a usable session: without a
  # permission field kasmvncserver announces "Users configured: marc (can only view)",
  # i.e. a read-only session. (Measurement: HTTP authentication passes
  # anyway without these flags, 200 with the right password and 401 with a
  # wrong one; a 401 on a correct password means the user
  # does not exist in the file, not that the flags are missing.)
  # Regeneration is driven by a hash of the secret: the file is
  # rewritten only if the password changed, otherwise each switch would restart the
  # current session for nothing (kasmvncserver only reads this file at startup,
  # so a secret change requires a restart). The final smoke test
  # logs ONLY the HTTP code, never the password.
  system.activationScripts.kasmvncPasswd = ''
    if [ -r /run/secrets/kasmvnc-password ]; then
      pw="$(cat /run/secrets/kasmvnc-password)"
      want="$(printf %s "$pw" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      have="$(cat /var/lib/kasmvnc/password.sha256 2>/dev/null || true)"
      if [ "$want" != "$have" ]; then
        printf '%s\n%s\n' "$pw" "$pw" | ${config.services.kasmvnc.package}/bin/kasmvncpasswd -u marc -w -o /home/marc/.kasmpasswd || true
        chmod 600 /home/marc/.kasmpasswd 2>/dev/null || true
        chown marc:users /home/marc/.kasmpasswd 2>/dev/null || true
        install -d -m 0755 /var/lib/kasmvnc
        printf '%s' "$want" > /var/lib/kasmvnc/password.sha256
        ${pkgs.systemd}/bin/systemctl --user -M marc@.host reset-failed kasmvnc.service 2>/dev/null || true
        ${pkgs.systemd}/bin/systemctl --user -M marc@.host restart kasmvnc.service 2>/dev/null || true
        code="000"
        for i in 1 2 3 4 5 6 7 8 9 10; do
          code="$(${pkgs.curl}/bin/curl -sk -o /dev/null -w '%{http_code}' -u "marc:$pw" https://127.0.0.1:8443/ 2>/dev/null || true)"
          if [ "$code" = "200" ]; then break; fi
          sleep 2
        done
        echo "kasmvnc: password (re)generated, local authentication -> HTTP $code" >&2
      fi
      unset pw want have
    fi
  '';

  # ========================================================================
  # VAULT - Dev mode for rustguac (connection storage)
  # ========================================================================
  services.vault-rustguac = {
    enable = true;
    mode = "dev";
    address = "127.0.0.1";
    port = 8200;
    devRootToken = "/run/secrets/vault-rustguac-root-token";
    ui = true;
  };

  # ========================================================================
  # RUSTDESK - P2P Server (hbbs + hbbr)
  # ========================================================================
  # Actual ports of 1.1.16: hbbs 21115 (NAT test) / 21116 (ID, TCP+UDP) /
  # 21118 (websocket), hbbr 21117 (relay) / 21119 (websocket). Without -k, hbbs
  # generates its key pair in /var/lib/rustdesk (id_ed25519*).
  # NOTE: tower is behind residential NAT; these ports are useful only on
  # the LAN as long as nothing is redirected on the box (or via the VPS).
  services.rustdesk = {
    enable = true;
    hbbs = { enable = true; idPort = 21116; };
    hbbr = { enable = true; port = 21117; };
    openFirewall = true;
  };

  # ========================================================================
  # ANKI - headless MCP server (Anki + AnkiMCP addon)
  # ========================================================================
  # Headless Anki + AnkiMCP addon, exposed as MCP HTTP on loopback
  # (127.0.0.1:3141) and consumed by Hermes (mcpServers.anki). The collection
  # is the one of the "marc" account of the sync server anki.marcpartensky.com:
  # this service is one more client of it, like the Mac and the phone.
  # Nothing is opened in the firewall or exposed by newt (public exposure
  # possible later, with the http_api_key key, cf services/anki-mcp).
  services.anki-mcp.enable = true;

  # ========================================================================
  # MCP - filtered LAN access (clickable URLs from Hermes Desktop on the Mac)
  # ========================================================================
  # Republishes on tower's LAN address the three MCP HTTP endpoints that
  # listen on loopback. The firewall accepts only 192.168.1.48 (the Mac);
  # nothing is opened to the box or to Pangolin. The nextcloud-mcp,
  # arr-mcp and anki-mcp modules read `host` to build their MCP URL, so a
  # single value to change if the DHCP address moves.
  services.mcp-lan-access = {
    enable = true;
    host = "192.168.1.44";
    clientAddress = "192.168.1.48";
    endpoints = {
      nextcloud = 8710;
      anki = 3141;
      arrmcp = 6060;
    };
  };

  # ========================================================================
  # NGINX - local vhosts (TLS carried by Pangolin/newt, not by nginx here)
  # ========================================================================
  services.nginx.rustguac = {
    enable = true;
    domain = "guac.marcpartensky.com";
    upstream = "http://127.0.0.1:8089";
    acme = false;
    listenAddress = "127.0.0.1";
    listenPort = 8289;
  };

  services.nginx.kasmvnc = {
    enable = true;
    domain = "kasm.marcpartensky.com";
    upstream = "https://127.0.0.1:8443";
    acme = false;
    listenAddress = "127.0.0.1";
    listenPort = 8288;
  };

  # Themed AdGuard UI (Catppuccin Mocha + Lavender). AdGuard listens only on
  # 127.0.0.1:3000 and cannot load custom CSS: this vhost proxies and
  # injects the stylesheet into the HTML. No public exposure by default,
  # only loopback + mesh address (tailscale0 is trusted).
  services.nginx.adguardTheme = {
    enable = true;
    listenAddresses = [ "127.0.0.1" "100.64.0.3" ];
    listenPort = 3021;
  };

  # Public exposure via Pangolin (newt, site "tower"): kasm.marcpartensky.com
  # -> 127.0.0.1:8288, the local nginx vhost which goes back to https towards KasmVNC.
  # HTTP + SSO, like noVNC (vnc.marcpartensky.com): newt 1.12.4 is enough, Pangolin's
  # native VNC mode would require a connector > 1.13. Same schema
  # constraint as services/newt: this Pangolin expects `proxy-resources` + `protocol`
  # (`public-resources`/`mode` are silently ignored -> domain in 404).
  # No healthcheck: even with disableBasicAuth, not verified enough to
  # change this rule without retesting (lesson of the noVNC healthcheck in
  # services/newt: a target that seems to respond can still make
  # the Pangolin probe fail for another reason).
  services.newt.blueprint.proxy-resources.kasm = {
    name = "kasm";
    protocol = "http";
    full-domain = "kasm.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8288;
        method = "http";
        # Healthcheck on the local nginx vhost (8288 -> https KasmVNC 8443).
        # KasmVNC responds 200 text/html on "/" (disableBasicAuth): measurement
        # of 2026-10-11 on http://127.0.0.1:8288/ -> 200. Same schema as
        # noVNC/winnie in services/newt (old schema: proxy-resources +
        # protocol, validated by this Pangolin).
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8288;
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

  # ========================================================================
  # SECRETS (sops-nix)
  # ========================================================================
  sops.secrets = {
    # Read by the vault service (User=vault): owner root + 0400 made the
    # file unreadable for it, so `vault server -dev` exited with EACCES.
    vault-rustguac-root-token = {
      sopsFile = ../../secrets/tower.yml;
      owner = "vault";
      mode = "0400";
    };
    # Read by the rustguac service itself (User=rustguac).
    rustguac-oidc-client-secret = {
      sopsFile = ../../secrets/tower.yml;
      owner = "rustguac";
      mode = "0400";
    };
    kasmvnc-cert-pem = {
      sopsFile = ../../secrets/tower.yml;
      owner = "marc";
      mode = "0400";
    };
    kasmvnc-key-pem = {
      sopsFile = ../../secrets/tower.yml;
      owner = "marc";
      mode = "0400";
    };
    # KasmVNC password (web login), read by the activation script on the root side.
    kasmvnc-password = {
      sopsFile = ../../secrets/kasmvnc.yml;
      owner = "root";
      mode = "0400";
    };
    # "pangolin/api_key": deliberately absent, the key does not exist in
    # secrets/common.yml (declaring it makes the whole switch fail with
    # "the key 'pangolin' cannot be found"). See services/hermes/default.nix.
  };

  # User lingering for the KasmVNC systemd user service
  users.users.marc.linger = true;

  # ========================================================================
  # WAYDROID - Android LineageOS in a container (test).
  # Kernel 6.18.54 already with ANDROID_BINDER_IPC/BINDERFS/MEMFD_CREATE -> no
  # out-of-tree module, no reboot. The waydroid-container service fails
  # cleanly as long as `waydroid init` (root, downloads ~1.2 GB of images) has
  # not been run once, then starts at the next switch or on restart.
  #
  # package = waydroid-nftables MANDATORY: tower's kernel does not have the
  # iptables (legacy) modules (netfilter in nf_tables only), so the
  # waydroid-net.sh of the standard package exits with
  #   "iptables (legacy): can't initialize iptables table `nat'"
  # and the session never starts. The nftables variant uses nft.
  # ========================================================================
  # WAYDROID: DISABLED on 2026-11-13 at marc's request.
  # Measured reason: the Android container runs permanently for the capture
  # lab and its AOT compiler (dex2oat) takes up to 7.5 cores out of 16 on
  # each app update / background maintenance task (Android believes it is
  # always idle on AC power in a container, so it optimizes everything).
  # No apk installed on 13/11, so it is indeed the background maintenance, not an
  # installation. To turn it back on: set enable to true (the
  # android-capture and cage-waydroid labs reconnect on their own via waydroid0).
  # WAYDROID: TEMPORARILY TURNED BACK ON on 2026-11-14 to install and test
  # the NY Waterway app (demo at marc's request); set enable = false again
  # after the demo (reason for the 13/11 disabling: dex2oat AOT).
  virtualisation.waydroid = {
    enable = true;
    package = pkgs.waydroid-nftables;
  };

  # hermes must be able to read the logs (including marc's user units,
  # e.g. kasmvnc): without it, no diagnosis possible without root, and sudo
  # is only authorized for nixos-rebuild.
  users.users.hermes.extraGroups = [ "systemd-journal" ];

  # TEMPORARY: one-shot root executor for the agent (USB disk maintenance).
  systemd.paths.hermes-once3 = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathExists = "/var/lib/hermes/once3/action";
  };
  systemd.services.hermes-once3 = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/run/current-system/sw/bin/bash /var/lib/hermes/once3/run.sh";
      RuntimeMaxSec = "10800";
      TimeoutStopSec = "120";
    };
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
  };


  # ========================================================================
  # WIREGUARD CLIENT - tower peer of the VPS anywhere (hub-and-spoke wg1)
  # ========================================================================
  # tower has no useful inbound exposure (residential NAT + public IP
  # dynamic): it therefore joins as a CLIENT the VPS's wg1 (10.100.0.1/24) and there
  # takes 10.100.0.3. From the VPS: `ssh marc@10.100.0.3` (alias `tower` in
  # modules/home/ssh). The Mac is the other peer (10.100.0.2) and goes through the same
  # hub. No port to open on tower: wg-quick keeps an ephemeral source
  # socket and conntrack follows the response. persistentKeepalive maintains the
  # NAT translation, so the VPS can reach tower at any time.
  #   - allowedIPs = 10.100.0.0/24: only the VPN network goes through the tunnel,
  #     tower's Internet traffic stays on the local connection.
  #   - Private key in secrets/wireguard.yml (sops, tower recipient), public
  #     key declared as a peer on the VPS side (services/wireguard/default.nix).
  # ========================================================================
  networking.wg-quick.interfaces = lib.mkIf wgClientEnable {
    wg1 = {
      address = [ "10.100.0.3/32" ];
      # Private key of the tower client. Create the sops secret before enabling.
      # The path is resolved by sops-nix from secrets/tower.yml.
      privateKeyFile = config.sops.secrets."wireguard/tower_private_key".path;
      peers = [
        {
          # Public key of the VPS wireguard server (anywhere / RackNerd)
          publicKey = "dsOBj2AfqF7YQ1JTGfYjlFse5sFZzwudOBiEMDLAzhU=";
          endpoint = "104.129.12.158:443";
          # Only the private VPN network is routed through the tunnel;
          # tower's internet traffic stays on the local connection.
          allowedIPs = [ "10.100.0.0/24" ];
          persistentKeepalive = 25;
        }
      ];
    };
  };

  # Private key of the tower peer. Dedicated sops file (tower recipient) so as not
  # to touch tower.yml: `sops secrets/wireguard.yml` for rotation.
  sops.secrets."wireguard/tower_private_key" = lib.mkIf wgClientEnable {
    sopsFile = ../../secrets/wireguard.yml;
    owner = "root";
    group = "root";
    mode = "0400";
  };
  # No UDP port to open: wg-quick in client mode does not listen on a fixed port.

  # ========================================================================
  # SUBNET: tower routes the LAN 192.168.1.0/24 into wg1
  # ========================================================================
  # Without it, the VPS (10.100.0.1) can only reach tower in the tunnel:
  # the Steam Deck and the rest of the LAN stay invisible from rack. tower
  # therefore acts as router for its LAN, with MASQUERADE wg1 -> wlan0 (the hosts of
  # the LAN have no return route to 10.100.0.0/24, so we go out with tower's
  # LAN IP, 192.168.1.44). The tower peer on the VPS side must declare
  # 192.168.1.0/24 in its allowedIPs so that the VPS routes the LAN to it.
  # Assumed side effect: any wg1 peer (the Mac, the VPS) can reach the LAN.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.nat = {
    enable = true;
    internalInterfaces = [ "wg1" ];
    externalInterface = "wlan0";
  };

  # ========================================================================
  # MONERO MINER - sleep / Nextcloud work schedule
  # ========================================================================
  sops.secrets."monero/wallet" = {
    sopsFile = ../../secrets/monero.yml;
    key = "wallet";
    owner = "root";
    mode = "0400";
  };
  sops.secrets."monero/nextcloud-user" = {
    sopsFile = ../../secrets/common.yml;
    key = "nextcloud_user";
    owner = "root";
    mode = "0400";
  };
  sops.secrets."monero/nextcloud-password" = {
    sopsFile = ../../secrets/common.yml;
    key = "nextcloud_password";
    owner = "root";
    mode = "0400";
  };

  services.monero-miner = {
    enable = true;
    walletFile = config.sops.secrets."monero/wallet".path;
    pool = "gulf.moneroocean.stream:10008";
    tls = false;
    threads = 8;
    cpuQuota = 800;
    rigId = "tower";
    thermalGuard.enable = true;
    thermalGuard.maxTemperature = 88;
    thermalGuard.resumeTemperature = 82;
    schedule.enable = true;
    calendar.enable = true;
    calendar.userFile = config.sops.secrets."monero/nextcloud-user".path;
    calendar.passwordFile = config.sops.secrets."monero/nextcloud-password".path;
    calendar.calendars = [ "sg" ];
  };

  # ========================================================================

  # -- Single MCP server --------------------------------------------------
  # One single process for all the home servers. The daemon starts alongside
  # the old stdio wiring: as long as hermes' mcpServers point at
  # the commands, nothing changes for the tools. Switching a session
  # amounts to replacing its entries with the URL http://127.0.0.1:4780/mcp.
  #
  # The listed servers must expose a FastMCP object (`mcp`, `app` or
  # `server`). The three hand-made ones (arena-elo, username-recon, roku,
  # androidtv) do not have one and stay in stdio as long as they are not
  # converted.
  # Termix API key for the agent (termix MCP, mounted by the mcp-host
  # below). Created in the panel: technical account "hermes-agent",
  # marc account, admin, no expiration. Gives NO machine access beyond
  # what Termix already holds: the API cannot read a password
  # stored via our tools, and SSH execution goes through the panel's
  # credentials (the "tower" host is in authType=key without credential, so
  # SSH_AUTH_FAILED as long as no key is deposited in Termix).
  sops.secrets."termix_api_key" = {
    sopsFile = ../../secrets/termix.yml;
    owner = "hermes";
    mode = "0400";
  };

  services.mcp-host = {
    enable = true;
    # Hermes takeover ACTIVE: the sessions read the single URL instead of
    # launching a process per server. The stdio entries of the seven
    # affected servers were removed from the modules; share-mcp (aws wrapper) and tts
    # (remote HTTP server) stay in stdio / dedicated URL.
    hermesGateway = true;
    # Support for stdio servers: the daemon proxies them all (26
    # measured on 2026-11-21), Hermes keeps only ONE connection. Verified before
    # activation: 26/26 mounted, 516 tools served, 0/26 incomplete server
    # (tool-by-tool comparison with each server taken alone).
    hostHermesStdio = true;
    # The 15 stdio servers actually declared in the conf (measurement of
    # 2026-11-21). The manifest is generated from their Hermes entries,
    # so command, args and env are not duplicated here: only the name is.
    stdioServers = [
      "amazon"
      "arena-elo"
      "bank"
      "garage"
      "gitea"
      "github"
      "hinge"
      "iprep"
      "openrouter"
      "phonerep"
      "share"
      "shlink"
      "stalwart"
      "username-recon"
      "wise"
    ];
    # Ghost entries measured on 2026-11-21: declared nowhere in the
    # conf (modules commented out in services/default.nix), but still in
    # config.yaml, so relaunched by each session. They are turned off, not
    # deleted: their config stays in the file, a redeclaration turns them
    # back on. They must be removed from here if one becomes useful again.
    staleStdioServers = [
      "app-publish"
      "enable-banking"
      "firefox"
      "firefox-mac"
      "gocardless"
      "nixos"
      "qbittorrent"
      "roku"
      "simplefin"
      "taskq"
      "zitadel"
      # Same category (declared nowhere in the conf, present in
      # config.yaml so relaunched by each session), measurement of 2026-11-25:
      #   - luma and stripe: OAuth not configured in a non-
      #     interactive environment -> "MCP OAuth setup failed", 4 attempts per session
      #     each, for two servers never called (0 call in the 4
      #     agent.log* logs);
      # Turned off, not deleted: the config stays in the file, removing the
      # name from here turns them back on.
      "luma"
      "stripe"
    ];
    # Beeper given up for good (2026-11-24): entry removed from
    # config.yaml on each activation, not just turned off.
    purgedServers = ["beeper"];
    # The mounted servers read their configuration at import and share a
    # single environment: it is the union of what each stdio entry received.
    env = {
      SHORTURL_STATE_DIR = "/var/lib/hermes/.local/state/shorturl-mcp";
      SHORTURL_TIMEOUT = "25";
      BEEF_URL = "http://127.0.0.1:3010";
      BEEF_API_TOKEN_FILE = config.sops.secrets.beef_api_token.path;
      BEEF_PUBLIC_HOST_FILE = "/var/lib/beef/public-host";
      MEETUP_API_URL = "https://api.meetup.com/gql-ext";
      MEETUP_TOKEN_FILE = "/run/secrets/meetup_oauth_token";
      IBKR_FLEX_ENV_FILE = config.sops.templates."ibkr-flex.env".path;
      PANGOLIN_BASE_URL = "https://api.marcpartensky.com/v1";
      PANGOLIN_API_KEY_FILE = config.sops.secrets."pangolin_api_key".path;
      # Bedroom Roku TV (ECP). Served by the same daemon as the others.
      ROKU_URL = "http://192.168.1.167:8060";
      # Termix panel (rootless hermes quadlet, loopback). The key travels via
      # a sops file: never in a module env, which ends up in the store.
      TERMIX_URL = "http://127.0.0.1:9160";
      TERMIX_API_KEY_FILE = config.sops.secrets."termix_api_key".path;
    };
    servers = {
      # shlink is no longer mounted here: Rust port in stdio, declared by
      # services/shlink-mcp (namespace mcp__shlink__*). Its old
      # SHLINK_* variables therefore left env, nobody reads them anymore.
      shorturl = ../../services/shorturl-mcp/server.py;
      beef = ../../services/beef-mcp/server.py;
      meetup = ../../services/meetup-mcp/meetup_mcp.py;
      mac = ../../services/mac-mcp/mac-mcp.py;
      ibkr = ../../services/ibkr-mcp/ibkr_flex.py;
      pangolin = ../../services/hermes/pangolin-mcp.py;
      roku = ../../services/roku-mcp.py;
      # Inventory, state, audit and SSH execution through the Termix panel.
      termix = ../../services/termix-mcp/termix_mcp.py;
    };
  };

  # -- Container migration guard -------------------------------
  # The four containers below were MOVED OUT of the host conf (blocks
  # virtualisation.oci-containers removed, cf. deploy/containers.nix). A
  # switch deletes them, so the podman quadlet must exist BEFORE. This
  # assertion turns a switch that would break four services into an explicit
  # eval failure, including for another session that would switch tower
  # without knowing where the migration stands.
  #
  # WHY NO MORE builtins.pathExists: in PURE evaluation (pure-eval
  # policy, and `just nixos` no longer has --impure), pathExists on a path
  # outside the store ALWAYS returns false. Measured on 2026-11-14: the guard blocked
  # the switch indefinitely while the four quadlets did exist
  # (nix eval --expr 'builtins.pathExists "/var/lib/.../aonsoku.container"'
  # = false in pure, true in impure). A guard that cannot read the disk
  # has only two honest forms: be false, or read the repo.
  #
  # It therefore reads the repo: each name must have a `migrated = true` entry
  # in deploy/containers.nix, that is, a quadlet written and its takeover
  # done at the time the oci-containers block was removed. Assumed limitation: it
  # proves the replacement is DECLARED in the repo, not that it is rendered on
  # the machine. The real verification is after the switch:
  #   systemctl --user is-active aonsoku arr-mcp nextcloud-mcp shlink-web-client
  # (rootless hermes quadlets, podman generator + linger). Failing that, render them:
  #   deploy/render.sh <name>   then  systemctl --user start <name>
  assertions = let
    containers = import ../../deploy/containers.nix;
  in
    map (name: {
      assertion = (containers ? ${name}) && (containers.${name}.migrated or false);
      message = ''
        The container ${name} is no longer declared in the NixOS conf (the
        oci-containers block removed) and deploy/containers.nix does not mark it
        `migrated = true`: the switch would remove its unit without a replacement.
        Write the quadlet (deploy/render.sh ${name}) and set migrated to true
        in deploy/containers.nix BEFORE this switch.
      '';
    }) ["aonsoku" "arr-mcp" "nextcloud-mcp" "shlink-web-client"];

  # -- External disks (NTFS) ---------------------------------------------
  # Verified on 2026-11-15: udiskie did try to mount the external NTFS
  # disk and failed ("wrong fs type, bad option, bad superblock"); the
  # message "install ntfs-3g" is misleading, udisks 2.11.2 already embeds
  # ntfs3g in its private PATH (/nix/store/*-ntfs3g-2026.7.7/bin). What
  # is missing is the system exposure of the helper: "ntfs" adds pkgs.ntfs3g to
  # system.fsPackages, so mount.ntfs-3g exists for mount and for the
  # .mount units, not just for the udisks daemon.
  boot.supportedFilesystems = [ "ntfs" ];

  # Toshiba MQ01ABB200 2 TB external disk, NTFS "Disque 1".
  # Mounted READ/WRITE via ntfs-3g (FUSE). The kernel ntfs3 driver
  # refuses this volume ("wrong fs type, bad option, bad superblock"), and the
  # volume is NOT dirty (ntfs-3g reports no "unclean file system"),
  # so ntfs-3g in rw is safe: it refuses rw itself if the volume is
  # hibernated or marked dirty, so the unit fails cleanly with nofail.
  # nofail + device-timeout: its absence never blocks boot.
  fileSystems."/mnt/disque1" = {
    device = "/dev/disk/by-uuid/748EFC2E8EFBE690";
    fsType = "ntfs-3g";
    options = ["rw" "nofail" "x-systemd.device-timeout=10"];
  };

  # ========================================================================
}
