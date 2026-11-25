# services/hermes-files/default.nix
# Read-only HTTP sharing of artifacts produced by the hermes agent
# (Hermes Pocket APK, exports, screenshots) on the local network only.
#
# hermes writes into /var/lib/hermes-files (its stateDir /var/lib/hermes is in
# 0770: nginx cannot traverse it, hence a dedicated directory in 0755).
# nginx serves it on http://<lan-ip>:8092/ with autoindex, without authentication:
# do not put anything sensitive there, and never route this port via Pangolin.
{...}: let
  port = 8092;
  root = "/var/lib/hermes-files";
in {
  systemd.tmpfiles.rules = [
    "d ${root} 0755 hermes hermes -"
  ];

  services.nginx.virtualHosts."hermes-files" = {
    # no useful serverName: only vhost on this port, so de facto default_server
    listen = [
      {
        addr = "0.0.0.0";
        inherit port;
      }
    ];
    inherit root;
    locations."/".extraConfig = ''
      autoindex on;
      # an .apk must download, not display
      types {
        application/vnd.android.package-archive apk;
      }
      default_type application/octet-stream;
    '';
  };

  networking.firewall.allowedTCPPorts = [port];
}
