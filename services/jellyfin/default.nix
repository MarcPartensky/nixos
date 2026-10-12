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

  # Les bibliothèques vivent dans /srv/media (groupe `media`, dossiers setgid,
  # créés par systemd-tmpfiles : cf. services/media). Ne PAS les mettre sous
  # /home/marc : systemd-tmpfiles refuse de créer un dossier là-bas
  # (« unsafe path transition », exit 73) et tout service devrait recevoir un
  # droit de traversée sur un home en 0700. Les racines à sélectionner dans
  # l'assistant web sont : /srv/media/movies, /srv/media/tvshows, /srv/media/music.
  #
  # UMask : le module impose 0077. Le média est partagé, donc les fichiers que
  # Jellyfin écrit dans la bibliothèque (pochettes, NFO s'ils sont activés)
  # doivent rester lisibles et modifiables par les autres membres du groupe.
  systemd.services.jellyfin.serviceConfig.UMask = lib.mkForce "0002";

  # Exposition publique via Pangolin (newt, site "tower") : jellyfin.marcpartensky.com
  # -> 127.0.0.1:8096. `site` omis : Pangolin affecte le site qui applique le
  # blueprint. Cle `proxy-resources` + champ `protocol` = schema reellement
  # compris par le Pangolin du VPS (cf. commentaire detaille dans services/newt).
  # Pas d'auth Pangolin : Jellyfin a sa propre authentification et les apps
  # natives (Roku, mobile) ne savent pas passer un SSO par navigateur.
  services.newt.blueprint.proxy-resources.jellyfin = {
    name = "jellyfin";
    protocol = "http";
    full-domain = "jellyfin.marcpartensky.com";
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8096;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8096;
          path = "/health";
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

  networking.firewall = {
    allowedTCPPorts = [ 8096 ]; # interface web + clients (Roku, mobile)
    allowedUDPPorts = [ 7359 ]; # découverte automatique du serveur sur le LAN
  };

  # Pas d'ouverture directe sur Internet : tower est derrière le NAT, seul le
  # tunnel Pangolin (newt) expose Jellyfin, et l'auth Jellyfin filtre les accès.
}
