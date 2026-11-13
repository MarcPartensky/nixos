# go2rtc : un seul point d'entree pour toutes les cameras de la maison, et une
# page web qui les liste.
#
# POURQUOI go2rtc et pas un NVR : le besoin est « voir le flux de la tablette
# (et des autres appareils) depuis un navigateur, avec plusieurs flux au choix,
# sans client a installer ». go2rtc (AlexxIT) est le moteur de flux de Frigate,
# mature, un binaire, aucune base de donnees : il prend en source RTSP, HTTP
# (H.264 / MJPEG), ONVIF ou exec, et il sert la MEME page avec un bouton par
# flux, en WebRTC / MSE / HLS / MJPEG / snapshot. Frigate ou MediaMTX
# demanderaient un NVR complet ou un fichier de conf par flux pour le meme
# resultat.
#
# COTE APPAREIL ANDROID : l'appli « Android IP Camera » (F-Droid,
# com.github.digitallyrefined.androidipcamera, MIT) sert le flux elle-meme :
#   http://<ip>:4444/video/h264      H.264 Annex-B (le moins cher en CPU)
#   http://<ip>:4444/video/mjpeg     MJPEG multipart
#   http://<ip>:4444/video/snapshot  JPEG haute resolution
#   rtsps://<ip>:8554/live           RTSP (TLS) quand on l'active
# Elle tourne en service de premier plan, donc elle survit a l'ecran eteint, et
# sait demarrer au boot. C'est la seule partie non declarative : un APK.
#
# EXPOSITION : go2rtc n'a AUCUNE authentification. Il ecoute donc uniquement en
# loopback, et c'est newt/Pangolin qui publie cam.marcpartensky.com avec le SSO
# (cf. services/newt/default.nix). Le firewall reste ferme : rien sur le LAN
# hors du port 4444 de la tablette, qui n'est pas un port de tower.
#
# NE PAS METTRE D'IDENTIFIANTS ICI : le depot est public. Si l'appli demande un
# jour un mot de passe, il passe par sops + environmentFile, pas par ce fichier.
#
# L'IP de la tablette vient d'un bail DHCP : si elle change, le flux passe en
# erreur et il faut corriger la ligne ci-dessous (les autres flux ne bougent
# pas). Un bail reserve sur la box regle le probleme a la source.
{ ... }:
{
  services.go2rtc = {
    enable = true;

    settings = {
      # 1984 = port par defaut de l'API et de l'UI. Loopback uniquement.
      api.listen = "127.0.0.1:1984";

      # Serveur RTSP interne : sert a re-diffuser les flux dans un client
      # (mpv, VLC) sans passer par le web, et a donner un point d'entree unique
      # aux NVR eventuels.
      rtsp.listen = "127.0.0.1:18554";

      streams = {
        # Tablette (gen 7 du profil nix-on-droid `tablet`, 192.168.1.114).
        tablette = "http://192.168.1.114:4444/video/h264";

        # Le telephone (Xiaomi 13T Pro) prendra la meme ligne le jour ou
        # l'appli y sera installee :
        # tel = "http://192.168.1.172:4444/video/h264";
      };
    };
  };
}
