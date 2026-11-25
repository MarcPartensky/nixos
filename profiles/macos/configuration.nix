{
  config,
  pkgs,
  inputs,
  ...
}: let
  # Pangolin VPN client for macOS: extracted from the official .dmg (fosrl/apple).
  # Update: bump version + hash (`nix store prefetch-file --json <url>`).
  pangolin-client = pkgs.stdenvNoCC.mkDerivation {
    pname = "pangolin-client";
    version = "0.12.1";
    src = pkgs.fetchurl {
      url = "https://github.com/fosrl/apple/releases/download/mac-0.12.1/Pangolin_Installer_0.12.1.dmg";
      hash = "sha256-RETTcY6f6kqsyNrEKOToyPq/GAHu1ujY6pjzcKevgEA=";
    };
    nativeBuildInputs = [pkgs.undmg];
    sourceRoot = ".";
    unpackPhase = "undmg $src";
    installPhase = ''
      mkdir -p $out/Applications
      cp -R *.app $out/Applications/
    '';
    meta = {
      description = "Pangolin client (zero-trust VPN) for macOS";
      homepage = "https://pangolin.net";
      platforms = pkgs.lib.platforms.darwin;
    };
  };
in {
  imports = [
    inputs.home-manager.darwinModules.home-manager

    # ygg-mesh private network on macOS (yggdrasil daemon + tor client):
    # see services/ygg-mesh/darwin.nix; /etc/yggdrasil.conf to create once.
    ../../services/ygg-mesh/darwin.nix


    # inputs.sops.nixosModules.sops  # Included in sopswarden

    # ../../services/wg-quick

    # Reverse SSH tunnel Mac -> rack (launchd agent): exposes the Mac's sshd
    # on 127.0.0.1:2223 of the VPS, so that tower (or marc) can reach the Mac outside
    # LAN. The Mac's key is already authorized for root@rack.
    ../../modules/home-mac/autossh

    # Chrome "agent" (visible window, dedicated profile ~/.chrome-hermes-agent,
    # CDP on loopback 9222) driven by tower. Replaces the Firefox --marionette
    # instance: that one advertised navigator.webdriver=true permanently and
    # was detected by anti-bot checks.
    ../../modules/home-mac/chrome-hermes

    # Marionette removed everywhere on 15/11/2026: no launchd agent
    # launches Firefox with --marionette anymore (measured: a Firefox --marionette advertises
    # navigator.webdriver=true permanently, even with no client attached). The
    # browser driving goes through the Chrome MCP Server extension on the tower side
    # (mcpServers.chrome-mac, tunnel 19236 -> 12306).
  ];

  environment.systemPackages = [
    inputs.nix-darwin.packages.aarch64-darwin.darwin-rebuild
    pkgs.vim
    pkgs.neovim
    pkgs.git
    pkgs.eternal-terminal
    # Native Touch ID (LocalAuthentication) used as the root approval channel
    # by the Hermes broker on the Mac (see services/hermes-broker).
    (import ../../packages/hermes-touch-id {inherit pkgs;})
  ];

  nixpkgs.config.allowUnfree = true;
  networking.hostName = "macos";

  # --- Nix: flakes and trusted users -------------------------
  # The Mac builds Winnie via `nix develop` (see modules/home-mac/winnie): the
  # flakes must be enabled in /etc/nix/nix.conf, not just passed on
  # the command line, and marc must be trusted-user so that the client can
  # fetch substitutes or override a local option.
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@admin"];
  };

  # services.nix-daemon.enable = true;  <- delete this line

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {inherit inputs;};
    backupFileExtension = "bak";
    users.marc = import ../../users/mac/home.nix;
  };

  # darwin-configuration.nix or flake.nix -> darwinConfigurations
  system.keyboard = {
    enableKeyMapping = true;
    remapCapsLockToEscape = true;
  };

  system.primaryUser = "marc";

  # --- Incoming SSH: Remote Login + keys -----------------------------------
  # Enables sshd (com.openssh.sshd): nix-darwin writes sshd_config.d and does
  # `launchctl enable + bootstrap` at activation (no systemsetup, which
  # requires Full Disk Access). The hermes@tower key is placed in
  # /Users/marc/.ssh/authorized_keys by users/mac/home.nix (home.activation).
  # Reachability: direct LAN (tower and the Mac are on 192.168.1.0/24);
  # outside LAN via the reverse autossh tunnel (modules/home-mac/autossh) that
  # tower reaches via `ssh -J rack -p 2223 marc@localhost`.
  services.openssh.enable = true;

  # --- Tailscale (headscale mesh, controller on the anywhere VPS) ---------
  # Do not configure anything DNS-side: headscale pushes to all tailnet nodes
  # the AdGuard resolver (services/adguard, on anywhere and tower), so the
  # Mac is filtered like the other devices and follows resolver
  # changes without a rebuild.
  # WARNING, two conditions for this to really bite:
  #  - headscale must have `override_local_dns = true` AND nameservers:
  #    without that it pushes NOTHING (check `tailscale dns status`, section
  #    "Resolvers"; "no resolvers configured" = zero filtering);
  #  - nix-darwin applies overrideLocalDns ONLY to the network services
  #    listed in `networking.knownNetworkServices`: empty, it warns
  #    "dns servers will not be configured" and macOS keeps its DNS.
  services.tailscale = {
    enable = true;
    # Applies 100.100.100.100 (MagicDNS) on the services below. To
    # be enabled only once headscale really provides resolvers,
    # otherwise macOS depends on tailscaled to resolve everything.
    overrideLocalDns = true;
    # `magicDNS` was removed from the nix-darwin options (eval assertion:
    # "no longer has any effect"): keeping it made ALL
    # darwin-rebuild fail, so the Mac stayed without tailscaled. Removed on 14/11.
  };

  # nix-darwin applies overrideLocalDns ONLY to the network services listed here:
  # without this list, macOS keeps its manual DNS (100.64.0.3, 1.1.1.1) and the
  # tailnet names (*.ts.marcpartensky.com) are resolved by the public
  # resolver, where the wildcard *.marcpartensky.com sends them to the VPS. That is what
  # makes `ssh tower` (by name) and MagicDNS usable on the Mac.
  networking.knownNetworkServices = [
    "Wi-Fi"
    "USB 10/100/1000 LAN"
    "AX88179A"
  ];

  # --- Permanence of the tailnet connection ------------------------------
  # nix-darwin only sets RunAtLoad on the daemon: if tailscaled dies
  # (crash, OOM, brutal network cut), launchd does NOT restart it and the Mac
  # stays off the tailnet until the next reboot. KeepAlive makes it
  # restart on its own, and the state (/Library/Tailscale) makes it resume the SAME
  # node, without re-enrollment. Tested on 16/11: `launchctl kickstart -k` returns
  # 100.64.0.5 in 2 s.
  # Remains out of reach: machine sleep (lid closed), where no
  # macOS tailscaled client maintains the tunnel; reconnection in ~1 s on
  # wake.
  launchd.daemons.tailscaled.serviceConfig.KeepAlive = true;

  # deactivated
  homebrew = {
    enable = false;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap"; # removes packages not listed
      upgrade = true;
    };

    brews = [
      "mas" # packages CLI homebrew
    ];

    casks = [
      "librewolf"
      "rqbit"
    ];

    masApps = {
      # App Store (requires mas)
      "Xcode" = 497799835;
    };
  };

  # Copies the app into /Applications at each activation: an app with
  # a network extension must not run from a symlink of the Nix store.
  system.activationScripts.pangolin-client.text = ''
    rm -rf /Applications/Pangolin.app
    cp -R ${pangolin-client}/Applications/Pangolin.app /Applications/
  '';

  # --- Xcode: manual installation, the rest is automatic ------------------
  # Apple forbids redistributing the SDK: Xcode comes from the App Store (no
  # nix package can provide it). Everything after installation is
  # however scriptable, and it is here: developer dir, license, first
  # components. The simulator runtime (~8 GB) is not downloaded
  # silently: `winnie-doctor --fix` handles it on demand.
  system.activationScripts.winnie-xcode.text = ''
    if [ -d /Applications/Xcode.app ]; then
      if [ "$(/usr/bin/xcode-select -p 2>/dev/null || true)" != "/Applications/Xcode.app/Contents/Developer" ]; then
        echo "winnie : xcode-select -> /Applications/Xcode.app" >&2
        /usr/bin/xcode-select -s /Applications/Xcode.app || true
        /usr/bin/xcodebuild -license accept || true
        /usr/bin/xcodebuild -runFirstLaunch || true
      fi
    else
      echo "winnie: Xcode absent (App Store); the macOS build works without it, only winnie-ios requires it" >&2
    fi
  '';

  # --- sudo for the agent: root operations of the Xcode toolchain ---------
  # hermes@tower connects via ssh (marc@mac) and drives the rare root
  # operations of Xcode: switching xcode-select, accepting the license,
  # downloading the simulator runtime. Separate sudoers.d fragment (not
  # security.sudo.extraConfig, already set by the nix-darwin terminfo block).
  # Limited to the three shims: the rest of marc's sudo requires his password.
  environment.etc."sudoers.d/20-hermes-xcode".text = ''
    marc ALL=(root) NOPASSWD: /usr/bin/xcode-select, /usr/bin/xcodebuild, /usr/bin/xcrun
  '';

  system.stateVersion = 6;

  # ---------------------------------------------------------------------------
  # Internal tailnet CA (Smallstep, cf. modules/nixos/intra-ca on tower)
  # ---------------------------------------------------------------------------
  # The OpenSSL bundle (curl, git, Nix programs) and above all the SYSTEM
  # KEYCHAIN, without which Safari and Chrome refuse `https://mesh`. nix-darwin
  # only sets the bundle: the import into the keychain is a call to `security`,
  # played at each activation (idempotent: we test for presence first).
  security.pki.certificateFiles = [ ../../certs/intra-ca-root.crt ];
  # ADMIN domain (System.keychain): requires GUI authorization, so it fails
  # from an activation launched via ssh ("SecTrustSettingsSetTrustSettings:
  # The authorization was denied since no user interaction was possible").
  # Non-blocking: the USER domain is enough for marc's Safari and Chrome
  # and installs without a password, by running the same command without -d from
  # a graphical session (verified on 23/11/2026).
  system.activationScripts.intraCaRoot.text = ''
    if ! /usr/bin/security find-certificate -c "Marc Intra Root CA" \
         /Library/Keychains/System.keychain >/dev/null 2>&1; then
      /usr/bin/security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain ${../../certs/intra-ca-root.crt} \
      || echo "intra-ca: admin trust not set (a GUI authorization is required)"
    fi
  '';

  # Touch ID for sudo, LocalAuthentication and pam_reattach: marc wants Touch ID
  # as the root approval channel on the Mac. Does not cover an ssh session
  # (pam_tid abstains when SSH_CONNECTION is set).
  security.pam.services.sudo_local.touchIdAuth = true;
  # Short names of the internal proxy: without a hosts entry, macOS expands `voice`
  # with its search domain and lands on the public wildcard *.marcpartensky.com,
  # hence on the VPS instead of tower (observed on 16/11). /etc/hosts takes
  # precedence over any DNS resolution, hence this marked and idempotent block. The list must
  # cover ALL names served by the proxy (`jellyfin` added on 23/11):
  # `jf.marcpartensky.com` is also there so as not to depend on the resolver.
  system.activationScripts.intraCaHosts.text = ''
    LINE="100.64.0.3 mesh voice jellyfin jf.marcpartensky.com"
    if ! /usr/bin/grep -qxF "$LINE" /etc/hosts 2>/dev/null; then
      /usr/bin/sed -i.bak '/hermes-intra-ca/d;/^100\.64\.0\.3 mesh voice/d' /etc/hosts
      printf '\n# hermes-intra-ca: short names of the internal proxy (tower)\n%s\n' "$LINE" >> /etc/hosts
      /bin/rm -f /etc/hosts.bak
    fi
  '';
}
