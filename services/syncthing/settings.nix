# Réglages Syncthing communs à toute la flotte de marc.
#
# Utilisé par le module home-manager (modules/home/syncthing), qui est le même
# pour tower, laptop, deck et le Mac : la config est donc IDENTIQUE partout, à
# part le chemin du dossier (home macOS vs Linux).
#
# Principe : aucun contact avec l'infrastructure de Syncthing (pas de découverte
# globale, pas de relais public, pas de NAT/STUN vers l'extérieur, pas de
# télémétrie, pas de vérification de mise à jour). Les nœuds se joignent par
# leur adresse fixe dans le mesh headscale, plus la découverte locale (LAN,
# 21027/udp) qui ne sort pas du réseau.
{
  lib,
  isDarwin,
}: let
  mesh = import ./mesh.nix;

  nodes = lib.filterAttrs (_: node: node.id != null) mesh.nodes;

  folderPath =
    if isDarwin
    then mesh.folder.macPath
    else mesh.folder.linuxPath;
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

  folder = {
    label = mesh.folder.label;
    path = folderPath;
    type = "sendreceive";
    # Comme la config est commune à tous les nœuds Linux, cette liste contient
    # aussi le nœud local : Syncthing le garde dans le dossier (il y est toujours
    # de toute façon) et refuse avec un 400 sans conséquence de le ré-ajouter
    # comme appareil. Ça évite d'avoir une config par machine.
    devices = lib.attrNames nodes;
    fsWatcherEnabled = true;
    rescanIntervalS = 3600;
    ignorePatterns = [".DS_Store"];
  };

  folderId = mesh.folder.id;
}
