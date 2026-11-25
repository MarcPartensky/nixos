# Syncthing settings common to marc's whole fleet.
#
# Used by the home-manager module (modules/home/syncthing), which is the same
# for tower, laptop, deck and the Mac. The fleet shares a single
# `homeConfigurations.marc` for the three Linux machines: none of them
# can be distinguished at evaluation. The only exploitable difference is thus
# the OS, and it is enough here: the Mac only takes the documents, the Linux
# ones also take the photos.
#
# The types are sendreceive everywhere, otherwise the config would no longer be identical
# from one Linux machine to another. The protection against accidental
# deletion comes from `staggered` versioning (30 days), stored OUTSIDE the
# photo tree so as not to pollute the Immich library.
#
# Network principle: no contact with Syncthing's infrastructure (no
# global discovery, no public relay, no NAT/STUN to the outside,
# no telemetry, no update check). The nodes join
# by their fixed address in the headscale mesh, plus local discovery (LAN,
# 21027/udp) which does not leave the network.
{
  lib,
  isDarwin,
}: let
  mesh = import ./mesh.nix;

  nodes = lib.filterAttrs (_: node: node.id != null) mesh.nodes;

  folderPath = folder:
    if isDarwin
    then folder.macPath
    else folder.linuxPath;

  # A folder without a path for the current OS is not declared at all.
  myFolders = lib.filter (folder: folderPath folder != null) mesh.folders;

  versionsRoot =
    if isDarwin
    then "/Users/marc/Library/Application Support/syncthing-versions"
    else "/home/marc/.local/share/syncthing-versions";

  mkFolder = folder: {
    label = folder.label;
    path = folderPath folder;
    type = "sendreceive";
    # Syncthing tolerates the local node in this list (it is there anyway
    # and an echo back is a harmless 400). This keeps a single config for
    # the whole fleet.
    devices = folder.members;
    fsWatcherEnabled = true;
    rescanIntervalS = 3600;
    ignorePatterns = [".DS_Store"];
    # History of deletions and replacements: 30 days, outside the shared
    # tree (otherwise Immich would index .stversions).
    versioning = {
      type = "staggered";
      params = {
        maxAge = "2592000"; # 30 days, in seconds
        cleanInterval = "3600";
        versionsPath = "${versionsRoot}/${folder.id}";
      };
    };
  };
in {
  inherit folderPath;

  devices = lib.mapAttrs (_: node: {
    id = node.id;
    # Fixed address on the mesh, plus "dynamic" so that local discovery
    # serves when the mesh is not reachable (same LAN).
    addresses = node.addresses ++ ["dynamic"];
  }) nodes;

  options = {
    listenAddresses = ["tcp://0.0.0.0:22000" "quic://0.0.0.0:22000"];
    # No outgoing call to Syncthing's infrastructure: global
    # discovery, relays, STUN, telemetry, crash report, update
    # check. The URLs are emptied in addition to the booleans, so that even a
    # click in the UI cannot reach them.
    globalAnnounceEnabled = false;
    globalAnnounceServers = [];
    localAnnounceEnabled = true; # LAN only (21027/udp, no Internet)
    relaysEnabled = false;
    natEnabled = false;
    stunServers = [];
    urAccepted = -1;
    urURL = "";
    crURL = "";
    crashReportingEnabled = false;
    releasesURL = "";
    autoUpgradeIntervalH = 0;
    upgradeToPreReleases = false;
    startBrowser = false;
  };

  # One folder per identifier, as the home-manager module expects.
  folders = lib.listToAttrs (map (folder: lib.nameValuePair folder.id (mkFolder folder)) myFolders);
}
