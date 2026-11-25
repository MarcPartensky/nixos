# go2rtc: a single entry point for all the cameras of the house, and a
# web page that lists them.
#
# WHY go2rtc and not an NVR: the need is "view the tablet's stream
# (and those of the other devices) from a browser, with several streams to choose from,
# without a client to install". go2rtc (AlexxIT) is Frigate's stream engine,
# mature, a single binary, no database: it takes as source RTSP, HTTP
# (H.264 / MJPEG), ONVIF or exec, and it serves the SAME page with one button per
# stream, in WebRTC / MSE / HLS / MJPEG / snapshot. Frigate or MediaMTX
# would require a full NVR or one config file per stream for the same
# result.
#
# ON THE ANDROID DEVICE SIDE: the "Android IP Camera" app (F-Droid,
# com.github.digitallyrefined.androidipcamera, MIT) serves the stream itself:
#   http://<ip>:4444/video/h264      H.264 Annex-B (the cheapest in CPU)
#   http://<ip>:4444/video/mjpeg     multipart MJPEG
#   http://<ip>:4444/video/snapshot  high-resolution JPEG
#   rtsps://<ip>:8554/live           RTSP (TLS) when enabled
# It runs as a foreground service, so it survives the screen being off, and
# can start at boot. It is the only non-declarative part: an APK.
#
# EXPOSURE: go2rtc has NO authentication. It therefore listens only on
# loopback, and it is newt/Pangolin that publishes cam.marcpartensky.com with SSO
# (cf. services/newt/default.nix). The firewall stays closed: nothing on the LAN
# except the tablet's port 4444, which is not a tower port.
#
# DO NOT PUT CREDENTIALS HERE: the repo is public. If the app one
# day asks for a password, it goes through sops + environmentFile, not this file.
#
# The tablet's IP comes from a DHCP lease: if it changes, the stream goes into
# error and the line below must be fixed (the other streams do not move).
# A reserved lease on the box solves the problem at the source.
{ ... }:
{
  services.go2rtc = {
    enable = true;

    settings = {
      # 1984 = default port of the API and the UI. Loopback only.
      api.listen = "127.0.0.1:1984";

      # Internal RTSP server: used to re-broadcast the streams into a client
      # (mpv, VLC) without going through the web, and to give a single entry point
      # to possible NVRs.
      rtsp.listen = "127.0.0.1:18554";

      streams = {
        # Tablet (gen 7 of the nix-on-droid `tablet` profile, 192.168.1.114).
        tablette = "http://192.168.1.114:4444/video/h264";

        # The phone (Xiaomi 13T Pro) will take the same line the day
        # the app is installed there:
        # tel = "http://192.168.1.172:4444/video/h264";
      };
    };
  };
}
