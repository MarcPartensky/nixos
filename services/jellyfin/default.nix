{
  config,
  lib,
  pkgs,
  ...
}:

# Serveur média Jellyfin.
#
# Transcodage matériel : l'iGPU AMD Renoir (Radeon Vega) est exposé en VA-API
# par le driver mesa (radeonsi). Profils réellement annoncés par le matériel
# (mesuré avec `vainfo --display drm --device /dev/dri/renderD128`) :
#   décodage VLD : MPEG2, VC1, H264, HEVC Main/Main10, VP9 Profile0/2, JPEG
#   encodage     : H264, HEVC Main/Main10 (pas d'AV1 : Renoir = VCN 2.0)
# Ce sont exactement les codecs activés ci-dessous. Le tone mapping HDR n'est
# pas couvert : il exige un runtime OpenCL absent ici.
{
  services.jellyfin = {
    enable = true;

    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/renderD128";
    };

    transcoding = {
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        vp9 = true;
        mpeg2 = true;
        vc1 = true;
      };
      enableHardwareEncoding = true;
      hardwareEncodingCodecs.hevc = true;
    };
  };

  # /home/marc n'est traversable (bit x) que par son groupe propriétaire : sans
  # `users` en groupe secondaire, l'utilisateur jellyfin ne peut pas atteindre
  # /home/marc/media (le dossier lui-même est en 0755 root:root, donc lisible).
  users.users.jellyfin.extraGroups = [ "users" ];

  # Bibliothèques : mêmes dossiers que les sources vidéo de Kodi, plus la
  # musique déjà servie par Navidrome. Jellyfin ne sait pas ajouter de
  # bibliothèque de façon déclarative, ces dossiers ne sont que les racines à
  # sélectionner dans l'assistant web (Bibliothèques > Ajouter).
  #
  # Pourquoi un oneshot et pas systemd.tmpfiles.rules : systemd-tmpfiles refuse
  # de descendre dans /home/marc (0700, appartient à marc) pour y créer un
  # dossier, et sort en "Detected unsafe path transition /home/marc (owned by
  # marc) -> /home/marc/media (owned by root)" puis CANTCREAT (exit 73) à
  # chaque activation : les règles ne s'appliquent jamais et le journal se
  # remplit d'avertissements. Vérifié le 26/09/2026 en instrumentant
  # l'activation : la même création faite par root en direct (mkdir) réussit.
  # D'où ce oneshot, qui tourne en root sans cette vérification de sécurité.
  systemd.services.jellyfin-media-dirs = {
    description = "Création des dossiers de bibliothèque média (Jellyfin, Navidrome)";
    wantedBy = [ "multi-user.target" ];
    before = [ "jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/install -d -o marc -g users -m 0755 \
        /home/marc/media/movies /home/marc/media/tvshows /home/marc/media/music
    '';
  };

  # Exposition publique via Pangolin (newt, site "tower") : jellyfin.marcpartensky.com
  # -> 127.0.0.1:8096. `site` omis : Pangolin affecte le site qui applique le
  # blueprint. Cle `proxy-resources` + champ `protocol` = schema reellement
  # compris par le Pangolin du VPS (cf. commentaire detaille dans services/newt).
  # Pas d'auth Pangolin : Jellyfin a sa propre authentification et les apps
  # natives (Roku, mobile) ne savent pas passer un SSO par navigateur.
  services.newt.blueprint.proxy-resources.jellyfin = {
    name = "Jellyfin";
    protocol = "http";
    full-domain = "jellyfin.marcpartensky.com";
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8096;
        method = "http";
      }
    ];
  };

  networking.firewall = {
    allowedTCPPorts = [ 8096 ]; # interface web + clients (Roku, mobile)
    allowedUDPPorts = [ 7359 ]; # découverte automatique du serveur sur le LAN
  };

  # Pas d'ouverture directe sur Internet : tower est derrière le NAT, seul le
  # tunnel Pangolin (newt) expose Jellyfin, et l'auth Jellyfin filtre les accès.
}
