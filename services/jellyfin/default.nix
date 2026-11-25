{
  config,
  lib,
  pkgs,
  ...
}:

# Jellyfin media server.
#
# Hardware transcoding: the AMD Renoir iGPU (Radeon Vega) is exposed as VA-API
# by the mesa driver (radeonsi). Profiles actually announced by the hardware
# (measured with `vainfo --display drm --device /dev/dri/renderD128`):
#   VLD decoding: MPEG2, VC1, H264, HEVC Main/Main10, VP9 Profile0/2, JPEG
#   encoding    : H264, HEVC Main/Main10 (no AV1: Renoir = VCN 2.0)
# These are exactly the codecs enabled below. HDR tone mapping is not
# covered: it requires an OpenCL runtime absent here.
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

  # The libraries live in /srv/media (group `media`, setgid folders,
  # created by systemd-tmpfiles: cf. services/media). Do NOT put them under
  # /home/marc: systemd-tmpfiles refuses to create a folder there
  # ("unsafe path transition", exit 73) and any service would need a
  # traverse permission on a home in 0700. The roots to select in
  # the web assistant are: /srv/media/movies, /srv/media/tvshows, /srv/media/music.
  #
  # UMask: the module sets 0077. The media is shared, so the files that
  # Jellyfin writes into the library (covers, NFO if enabled)
  # must remain readable and writable by the other members of the group.
  systemd.services.jellyfin.serviceConfig.UMask = lib.mkForce "0002";

  # Public exposure via Pangolin (newt, site "tower"): jellyfin.marcpartensky.com
  # -> 127.0.0.1:8096. `site` omitted: Pangolin assigns the site that applies the
  # blueprint. `proxy-resources` key + `protocol` field = schema actually
  # understood by the VPS Pangolin (cf. detailed comment in services/newt).
  # No Pangolin auth: Jellyfin has its own authentication and the native
  # apps (Roku, mobile) do not know how to go through a browser SSO.
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
    allowedTCPPorts = [ 8096 ]; # web interface + clients (Roku, mobile)
    allowedUDPPorts = [ 7359 ]; # automatic server discovery on the LAN
  };

  # No direct opening to the Internet: tower is behind NAT, only the
  # Pangolin tunnel (newt) exposes Jellyfin, and the Jellyfin auth filters access.
}
