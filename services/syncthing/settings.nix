# Réglages Syncthing communs à toute la flotte de marc.
#
# Utilisé par le module home-manager (modules/home/syncthing), qui est le même
# pour tower, laptop, deck et le Mac. La flotte partage une seule
# `homeConfigurations.marc` pour les trois machines Linux : aucune d'entre elles
# ne peut se distinguer à l'évaluation. La seule différence exploitable est donc
# l'OS, et elle suffit ici : le Mac ne prend que les documents, les Linux
# prennent aussi les photos.
#
# Les types sont sendreceive partout, sinon la config ne serait plus identique
# d'une machine Linux à l'autre. La protection contre une suppression
# accidentelle vient du versioning `staggered` (30 jours), stocké HORS de
# l'arbre photos pour ne pas polluer la bibliothèque Immich.
#
# Principe réseau : aucun contact avec l'infrastructure de Syncthing (pas de
# découverte globale, pas de relais public, pas de NAT/STUN vers l'extérieur,
# pas de télémétrie, pas de vérification de mise à jour). Les nœuds se joignent
# par leur adresse fixe dans le mesh headscale, plus la découverte locale (LAN,
# 21027/udp) qui ne sort pas du réseau.
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

  # Un dossier sans chemin pour l'OS courant n'est pas déclaré du tout.
  myFolders = lib.filter (folder: folderPath folder != null) mesh.folders;

  versionsRoot =
    if isDarwin
    then "/Users/marc/Library/Application Support/syncthing-versions"
    else "/home/marc/.local/share/syncthing-versions";

  mkFolder = folder: {
    label = folder.label;
    path = folderPath folder;
    type = "sendreceive";
    # Syncthing tolère le nœud local dans cette liste (il y est de toute façon
    # et un renvoi est un 400 sans conséquence). Ça garde une seule config pour
    # toute la flotte.
    devices = folder.members;
    fsWatcherEnabled = true;
    rescanIntervalS = 3600;
    ignorePatterns = [".DS_Store"];
    # Historique des suppressions et remplacements : 30 jours, hors de l'arbre
    # partagé (sans quoi Immich indexerait .stversions).
    versioning = {
      type = "staggered";
      params = {
        maxAge = "2592000"; # 30 jours, en secondes
        cleanInterval = "3600";
        versionsPath = "${versionsRoot}/${folder.id}";
      };
    };
  };
in {
  inherit folderPath;

  devices = lib.mapAttrs (_: node: {
    id = node.id;
    # Adresse fixe sur le mesh, plus « dynamic » pour que la découverte locale
    # serve quand le mesh n'est pas joignable (même LAN).
    addresses = node.addresses ++ ["dynamic"];
  }) nodes;

  options = {
    listenAddresses = ["tcp://0.0.0.0:22000" "quic://0.0.0.0:22000"];
    # Aucun appel sortant vers l'infrastructure de Syncthing : découverte
    # globale, relais, STUN, télémétrie, rapport de crash, vérification de
    # mise à jour. Les URLs sont vidées en plus des booléens, pour que même un
    # clic dans l'UI ne puisse pas les joindre.
    globalAnnounceEnabled = false;
    globalAnnounceServers = [];
    localAnnounceEnabled = true; # LAN uniquement (21027/udp, pas d'Internet)
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

  # Un dossier par identifiant, tel que l'attend le module home-manager.
  folders = lib.listToAttrs (map (folder: lib.nameValuePair folder.id (mkFolder folder)) myFolders);
}
