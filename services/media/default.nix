{
  config,
  lib,
  pkgs,
  ...
}:

# Shared media: /srv/media (ZFS dataset nixos/media) + group `media`.
#
# Why not /home/marc/media (old location):
#  - /home/marc is 0700, so each service had to receive an explicit
#    traversal right (added to the `users` group) to read /home/marc/media;
#  - systemd-tmpfiles REFUSES to create anything under /home/marc
#    ("Detected unsafe path transition", exit 73): the rules were
#    never applied and a root oneshot was needed (cf. services/jellyfin).
# Outside /home, both problems disappear: the folders are declarative and
# the services no longer need to traverse marc's home.
#
# Rights model: a single `media` group, folders in 2775 (setgid, so the
# files created inherit the `media` group) and UMask=0002 set on each
# service that writes (cf. the modules concerned) so that its files stay
# modifiable by the other members. Nextcloud writes in 0644 (its umask), so
# readable by Jellyfin but not modifiable by the *arr: enough, they do not
# rewrite its files.
let
  mediaRoot = "/srv/media";
in {
  users.groups.media = { };

  users.users.marc.extraGroups = [ "media" ];
  users.users.jellyfin.extraGroups = [ "media" ];
  users.users.navidrome.extraGroups = [ "media" ];
  users.users.qbittorrent.extraGroups = [ "media" ];
  users.users.nextcloud.extraGroups = [ "media" ];

  # Dataset creation, once: the activation runs as root, and ZFS
  # then mounts the dataset by itself on each boot (mountpoint property).
  # Idempotent: recreates nothing if nixos/media already exists.
  systemd.services.media-dataset = {
    description = "Creation of the ZFS dataset of the shared media (nixos/media -> ${mediaRoot})";
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

      # The tree is also created here: on the first boot, systemd-tmpfiles
      # runs before the dataset is mounted and its folders would be masked.
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

  # Library (read by Jellyfin, Navidrome and Kodi, written by the *arr) and
  # download area (clients + imports). Both are in the SAME
  # dataset: this is what allows the *arr to import by hard link instead of
  # copying, and therefore to let qBittorrent seed without doubling the space.
  # `books` by symmetry with Readarr. The downloads are in 2770: the
  # in-progress torrents do not need to be readable by everyone.
  systemd.tmpfiles.rules =
    [ "d ${mediaRoot} 2755 root media -" ]
    ++ map (d: "d ${mediaRoot}/${d} 2775 root media -") [ "movies" "tvshows" "music" "books" ]
    ++ [ "d ${mediaRoot}/downloads 2770 root media -" ]
    ++ map (d: "d ${mediaRoot}/downloads/${d} 2770 root media -") [ "radarr" "sonarr" "readarr" "incomplete" ];
}
