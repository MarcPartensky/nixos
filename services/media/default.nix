{
  config,
  lib,
  pkgs,
  ...
}:

# Média partagé : /srv/media (dataset ZFS nixos/media) + groupe `media`.
#
# Pourquoi pas /home/marc/media (ancien emplacement) :
#  - /home/marc est en 0700, donc chaque service devait recevoir un droit de
#    traversée explicite (ajout au groupe `users`) pour lire /home/marc/media ;
#  - systemd-tmpfiles REFUSE de créer quoi que ce soit sous /home/marc
#    (« Detected unsafe path transition », exit 73) : les règles ne
#    s'appliquaient jamais et il fallait un oneshot root (cf. services/jellyfin).
# Hors /home, les deux problèmes disparaissent : les dossiers sont déclaratifs et
# les services n'ont plus besoin de traverser le home de marc.
#
# Modèle de droits : un seul groupe `media`, dossiers en 2775 (setgid, donc les
# fichiers créés héritent du groupe `media`) et UMask=0002 posé sur chaque
# service qui écrit (cf. les modules concernés) pour que ses fichiers restent
# modifiables par les autres membres. Nextcloud écrit en 0644 (son umask), donc
# lisible par Jellyfin mais pas modifiable par les *arr : suffisant, ils ne
# réécrivent pas ses fichiers.
let
  mediaRoot = "/srv/media";
in {
  users.groups.media = { };

  users.users.marc.extraGroups = [ "media" ];
  users.users.jellyfin.extraGroups = [ "media" ];
  users.users.navidrome.extraGroups = [ "media" ];
  users.users.qbittorrent.extraGroups = [ "media" ];
  users.users.nextcloud.extraGroups = [ "media" ];

  # Création du dataset, une seule fois : l'activation tourne en root, et ZFS
  # monte ensuite le dataset tout seul à chaque boot (propriété mountpoint).
  # Idempotent : ne recrée rien si nixos/media existe déjà.
  systemd.services.media-dataset = {
    description = "Création du dataset ZFS du média partagé (nixos/media -> ${mediaRoot})";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!${mediaRoot}";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ZFS=${config.boot.zfs.package}/bin/zfs
      if ! $ZFS list -H -o name nixos/media >/dev/null 2>&1; then
        $ZFS create -o mountpoint=${mediaRoot} nixos/media
      fi
      $ZFS set mountpoint=${mediaRoot} nixos/media || true
      ${pkgs.util-linux}/bin/mountpoint -q ${mediaRoot} || $ZFS mount nixos/media || true

      # L'arbre est aussi créé ici : au premier démarrage, systemd-tmpfiles
      # tourne avant le montage du dataset et ses dossiers seraient masqués.
      ${pkgs.coreutils}/bin/install -d -o root -g media -m 2755 ${mediaRoot}
      for d in movies tvshows music books; do
        ${pkgs.coreutils}/bin/install -d -o root -g media -m 2775 "${mediaRoot}/$d"
      done
      ${pkgs.coreutils}/bin/install -d -o root -g media -m 2770 ${mediaRoot}/downloads
      for d in radarr sonarr readarr incomplete; do
        ${pkgs.coreutils}/bin/install -d -o root -g media -m 2770 "${mediaRoot}/downloads/$d"
      done
    '';
  };

  # Bibliothèque (lue par Jellyfin, Navidrome et Kodi, écrite par les *arr) et
  # zone de téléchargement (clients + imports). Les deux sont dans le MÊME
  # dataset : c'est ce qui permet aux *arr d'importer par lien dur au lieu de
  # copier, et donc de laisser qBittorrent seeder sans doubler l'espace.
  # `books` par symétrie avec Readarr. Les téléchargements sont en 2770 : les
  # torrents en cours n'ont pas besoin d'être lisibles par tout le monde.
  systemd.tmpfiles.rules =
    [ "d ${mediaRoot} 2755 root media -" ]
    ++ map (d: "d ${mediaRoot}/${d} 2775 root media -") [ "movies" "tvshows" "music" "books" ]
    ++ [ "d ${mediaRoot}/downloads 2770 root media -" ]
    ++ map (d: "d ${mediaRoot}/downloads/${d} 2770 root media -") [ "radarr" "sonarr" "readarr" "incomplete" ];
}
