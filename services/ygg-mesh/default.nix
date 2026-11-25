# services/ygg-mesh/default.nix
#
# Encrypted private network between marc's machines, without any third party
# knowing their IPs. IDENTICAL file on each member machine: it
# identifies itself via networking.hostName.
#
#   Off LAN: Yggdrasil via Tor. Each machine is reachable only as .onion,
#              even your machines do not see each other's IPs.
#   Same LAN: multicast discovery + direct full-speed link (TLS on
#              [fe80::...]:12346), takes priority over Tor. Automatic switchover
#              in both directions, without rediscovery.
#   Access   : shared password + pinned public keys. No link with
#              the public Yggdrasil network: only your machines.
#
# Each machine gets a stable IPv6 and a name <hostname>.ygg (e.g. ssh tower.ygg).
#
# Dedicated sops secret, decryptable by the three member machines:
#   secrets/ygg-mesh.yml   ygg_password: <openssl rand -hex 24>
# The Yggdrasil and onion keys are generated on each machine and never leave it.
#
# Differences vs the initial draft (adapted and tested on 2026-10-23):
#   - nixpkgs 26.05 NO LONGER has the services.yggdrasil.configFile option (replaced
#     by `settings`, generated in the store so readable by everyone): the
#     password cannot live there. We keep the config rendered at runtime in /run,
#     via an ExecStartPre that reads the password from a systemd credential.
#   - secret in secrets/ygg-mesh.yml and not common.yml: same recipients,
#     but common.yml can only be edited with marc's private age key.
#   - networking.enableIPv6 forced: the ygg addresses and the multicast ff02::114
#     are IPv6, and modules/nixos/networking disables it (tower, deck).
#   - Tor DEDICATED to the mesh (ygg-mesh-tor) instead of the system tor: tower's
#     tor is a public relay, and tor itself advises against mixing a relay and
#     an onion service in the same process. Above all, the mesh must not
#     depend on the health of the relay: on 2026-10-23 tower's is stuck
#     at bootstrap (ExitNodes {ch} without geoip, enableGeoIP = false on the
#     services/tor side). Separate instance = client + onion service only,
#     SocksPort 127.0.0.1:9053.
#   - ygg-mesh-identity.service publishes onion/key/address into
#     /var/lib/ygg-mesh/identity.txt (readable without root), for bootstrap.
#
# Bootstrap: see at the bottom of the file.

{ config, lib, pkgs, ... }:

let
  # ===================== TO EDIT: the network members =====================
  # beacon = true only for the fixed machines at your place: they announce
  # their presence on the LAN. Mobile machines listen without ever announcing,
  # so they stay silent on a public wifi.
  # onion, key and addr: to be filled after the first rebuild. `cat
  # /var/lib/ygg-mesh/identity.txt` on each machine gives the three values.
  nodes = {
    tower = {
      beacon = true;
      onion = "3oknvzva57oweu2oqqw7vyi2bluq3f3ceepgwwkgrpywpxvt2jdcnlyd.onion";
      key = "a9e47f129fe8c3b743bbfd6f2302eb5ca39202409c6deac22bdad9be38b21525";
      addr = "200:ac37:1da:c02e:7891:7888:521:b9fa";
    };
    anywhere = {
      beacon = false;
      onion = "jzrxnon4l24vyu5ndd7djkdztzo5cfot5x3j6img3mcxby6drwqcudqd.onion";
      key = "e4235bfcfa8a8dbb79fc97f79bba918e60233ff9b60a3e1a9511e39f65d255ac";
      addr = "200:37b9:4806:aea:e489:c06:d010:c88a";
    };
    deck = {
      beacon = false;
      onion = "j56zi2yaunqlsysildbld6rk3fwlbmlfehbzqkwfrm6lxxkrf6jf4lqd.onion";
      key = "c324ac2a81edf3abb54d9157518589ca8cd2affb34d41421105a167c5602d17d";
      addr = "200:79b6:a7aa:fc24:18a8:9564:dd51:5cf4";
    };
    # Outbound clients, without onion (not dialable: they go out to the mesh):
    # fill in key + addr after their first boot (see bootstrap at the bottom).
    # mac   = { beacon = false; onion = null; key = "<public key>"; addr = "<ygg address>"; };
    # phone = { beacon = false; onion = null; key = "<public key>"; addr = "<ygg address>"; };
  };
  secretsFile = ../../secrets/ygg-mesh.yml;
  # ============================================================================

  host = config.networking.hostName;
  me = nodes.${host} or (throw "ygg-mesh: '${host}' missing from the nodes table");

  listenPort = 12345; # Yggdrasil, local only, exposed as .onion
  multicastPort = 12346; # direct links on the LAN (TCP; only the beacon listens)
  torSocksPort = 9053; # SocksPort of the tor dedicated to the mesh
  torLinks = 2; # parallel Tor connections per peer: a circuit that drops cuts nothing
  configPath = "/run/yggdrasil/ygg-mesh.json";
  stateDir = "/var/lib/ygg-mesh"; # dedicated tor + identity (back up this folder)

  others = lib.filterAttrs (n: v: n != host && v.onion != null && v.key != null) nodes;

  # Nodes recognized by their public key alone, even without onion: the Mac and
  # the phone are outbound clients (Tor or multicast), not dialable.
  # They must still be accepted by the mesh nodes.
  known = lib.filterAttrs (n: v: n != host && v.key != null) nodes;

  # A different SOCKS identifier per connection = a distinct Tor circuit
  # (IsolateSOCKSAuth). priority=10: Tor comes after the LAN (priority 0, the
  # smallest wins). maxbackoff=5s: retries fast after a cut (otherwise
  # up to ~1 h).
  peerUris = lib.concatLists (lib.mapAttrsToList (name: n:
    map (i:
      "socks://${name}-${toString i}:x@127.0.0.1:${toString torSocksPort}/${n.onion}:${toString listenPort}"
      + "?key=${n.key}&password=@PW@&priority=10&maxbackoff=5s"
    ) (lib.range 1 torLinks)
  ) others);

  # Full config, password as a placeholder: rendered at runtime at startup
  # (ExecStartPre), so never written into the store.
  configTemplate = pkgs.writeText "ygg-mesh.json.in" (builtins.toJSON {
    Listen = [ "tcp://127.0.0.1:${toString listenPort}?password=@PW@" ];
    Peers = peerUris;
    MulticastInterfaces = [{
      Regex = "^(en|eth|wl).*";
      Beacon = me.beacon;
      Listen = true;
      Port = multicastPort;
      Priority = 0;
      Password = "@PW@";
    }];
    # Path of the systemd credential set by the nixpkgs module itself
    # (LoadCredential=private-key:... in both versions). In 26.05 the
    # module additionally bind-mounted the key on /private-key; in 26.11 there is no
    # more bind and its own default is precisely this credential path.
    PrivateKeyPath = "/run/credentials/yggdrasil.service/private-key";
    IfName = "ygg";
    AllowedPublicKeys = lib.mapAttrsToList (_: n: n.key) known;
    NodeInfoPrivacy = true;
  });

  renderScript = pkgs.writeShellScript "ygg-mesh-render-config" ''
    set -eu
    pw="$(cat "$CREDENTIALS_DIRECTORY/ygg-mesh-password")"
    umask 077
    sed "s/@PW@/$pw/g" ${configTemplate} > ${configPath}
  '';

  # Dedicated Tor: SOCKS client + mesh onion service. No secret inside
  # (just paths and ports), so it can live in the store.
  torrc = pkgs.writeText "ygg-mesh-torrc" ''
    DataDirectory ${stateDir}/tor
    SocksPort 127.0.0.1:${toString torSocksPort} IsolateDestAddr IsolateSOCKSAuth
    HiddenServiceDir ${stateDir}/tor/hs
    HiddenServicePort ${toString listenPort} 127.0.0.1:${toString listenPort}
    AvoidDiskWrites 1
    SafeLogging 1
  '';
in
{
  # The yggdrasil addresses and multicast discovery (ff02::114) are IPv6;
  # without it neither the network nor the direct LAN link works. mkForce because
  # modules/nixos/networking (imported by tower and deck) sets false.
  networking.enableIPv6 = lib.mkForce true;

  sops.secrets.ygg_password.sopsFile = secretsFile;

  # ---------- Tor of the mesh ----------
  # Dedicated system user (not DynamicUser: with a StateDirectory
  # nested under a parent created by another service, systemd switches the
  # folder to /var/lib/private and leaves a symlink loop).
  users.users.ygg-mesh-tor = {
    isSystemUser = true;
    group = "ygg-mesh-tor";
  };
  users.groups.ygg-mesh-tor = { };

  # Migration: the first attempt (DynamicUser) left this broken symlink.
  system.activationScripts.ygg-mesh-fix-state = ''
    if [ -L /var/lib/ygg-mesh/tor ] && [ ! -e /var/lib/ygg-mesh/tor ]; then
      rm -f /var/lib/ygg-mesh/tor
    fi
  '';

  systemd.services.ygg-mesh-tor = {
    description = "Tor dedicated to the ygg mesh (client + onion service)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      User = "ygg-mesh-tor";
      Group = "ygg-mesh-tor";
      StateDirectory = "ygg-mesh/tor";
      StateDirectoryMode = "0700";
      ExecStart = "${pkgs.tor}/bin/tor -f ${torrc}";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "on-failure";
      RestartSec = 15;
      # Hardening: tor only needs the network and its state folder.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      CapabilityBoundingSet = [ "" ];
    };
  };

  # ---------- Yggdrasil ----------
  # We keep the nixpkgs module (persisted key, hardening, credential for the
  # private key) but its config generated in the store cannot carry the
  # password: the script is replaced by ours, which reads the config rendered at
  # runtime in /run.
  services.yggdrasil = {
    enable = true;
    persistentKeys = true; # key generated once, kept in /var/lib/yggdrasil
    openMulticastPort = true; # UDP 9001: the LAN beacons (ff02::114:9001)
    denyDhcpcdInterfaces = [ "ygg" ];
  };

  # NO dependency towards ygg-mesh-tor, deliberately. The nixpkgs module sets
  # `before = [ "network.target" ]` on yggdrasil (it provides the ygg interface to
  # the rest of the system): so everything yggdrasil depends on must be able to start
  # BEFORE network.target, which tor cannot (it needs the network). With
  # `after = [ "ygg-mesh-tor.service" ]` here and ygg-mesh-tor `after =
  # [ "network.target" ]`, systemd found an ordering cycle and outright
  # deleted the job yggdrasil.service/start at boot (seen at the 2026-10-23 boot:
  # "Found ordering cycle ... Job yggdrasil.service/start deleted to break
  # ordering cycle") -> yggdrasil never started, ygg-mesh-identity failing.
  # Without the ordering: yggdrasil starts alone, retries its socks:// peers every
  # maxbackoff=5 s as long as tor is not there, and the LAN link (multicast) does
  # not depend on tor at all.
  systemd.services.yggdrasil = {
    # No start limit: at the first boot, the sops credential may
    # arrive after yggdrasil (setupSecrets); Restart=always then retries
    # indefinitely instead of ending in start-limit-hit.
    startLimitIntervalSec = 0;
    serviceConfig = {
      LoadCredential = [ "ygg-mesh-password:${config.sops.secrets.ygg_password.path}" ];
      ExecStartPre = renderScript;
    };
    script = lib.mkForce "exec ${config.services.yggdrasil.package}/bin/yggdrasil -useconffile ${configPath}";
  };

  networking.firewall = {
    trustedInterfaces = [ "ygg" ]; # only your machines travel there
    # Only machines that announce themselves receive incoming LAN connections
    allowedTCPPorts = lib.optional me.beacon multicastPort;
  };

  # Names <machine>.ygg
  networking.hosts = lib.mapAttrs' (name: n: lib.nameValuePair n.addr [ "${name}.ygg" ])
    (lib.filterAttrs (_: n: n.addr != null) nodes);

  # ---------- Identity (bootstrap without root) ----------
  # onion + public key + address in a file readable by everyone: the three
  # values to copy into the `nodes` table above. Nothing secret inside.
  systemd.services.ygg-mesh-identity = {
    description = "ygg-mesh identity (onion, public key, IPv6 address)";
    wantedBy = [ "multi-user.target" ];
    after = [ "yggdrasil.service" "ygg-mesh-tor.service" ];
    # Restarts when tor (onion) or yggdrasil (key, address) restarts,
    # to recapture a fresh identity.
    partOf = [ "ygg-mesh-tor.service" "yggdrasil.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "ygg-mesh";
    };
    path = [ config.services.yggdrasil.package pkgs.coreutils pkgs.gnugrep ];
    script = ''
      set -eu
      onion=""
      for _ in $(seq 1 90); do
        if [ -s ${stateDir}/tor/hs/hostname ]; then
          onion="$(cat ${stateDir}/tor/hs/hostname)"
          break
        fi
        sleep 2
      done
      self=""
      for _ in $(seq 1 60); do
        out="$(yggdrasilctl -json getself 2>/dev/null || true)"
        if printf '%s' "$out" | grep -q '"address"'; then
          self="$out"
          break
        fi
        sleep 2
      done
      # File written only if the identity is complete: its presence
      # means "onion + key + address valid".
      rm -f ${stateDir}/identity.txt
      if [ -z "$onion" ] || [ -z "$self" ]; then
        echo "ygg-mesh-identity: incomplete (onion='$onion') - yggdrasil/tor not ready" >&2
        exit 1
      fi
      {
        printf 'onion=%s\n' "$onion"
        printf '%s\n' "$self"
      } > ${stateDir}/identity.txt
      chmod 0644 ${stateDir}/identity.txt
    '';
  };
}

# ================================ BOOTSTRAP ================================
#
# 1. Shared password: already set (secrets/ygg-mesh.yml, encrypted for
#    anywhere/tower/deck/deck-host). Rotation: rewrite the plaintext then
#    `nix run nixpkgs#sops -- -e --filename-override secrets/ygg-mesh.yml
#      --output secrets/ygg-mesh.yml <plaintext>`, and rebuild everywhere.
#
# 2. Import this file on each machine (onion, key, addr = null), rebuild.
#
# 3. On EACH machine, `cat /var/lib/ygg-mesh/identity.txt` gives:
#      onion=...        -> onion field (without the trailing .onion)
#      "key": "..."     -> key field
#      "address": ...   -> addr field
#
# 4. Fill in the table, rebuild everywhere.
#
# Verify:
#      ping tower.ygg                  # from any mesh machine
#      sudo yggdrasilctl getpeers      # socks:// links (Tor) and tls://[fe80::...] (LAN)
#      journalctl -u ygg-mesh-tor      # tor bootstrap + onion publication
#
# Reinstalling a machine: back up /var/lib/yggdrasil/private.pem and
# /var/lib/ygg-mesh/tor (tor/hs = onion identity) to keep the same identity,
# otherwise redo step 3 for that machine.
