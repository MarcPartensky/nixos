# The pod image: a layered OCI tarball the k3s node imports with
# `k3s ctr images import`. Built on the laptop (Rust compile), shipped to tower
# as a file, never pulled from a registry.
{
  pkgs,
  mnemo,
}: let
  tag = mnemo.version;
in
  pkgs.dockerTools.buildLayeredImage {
    name = "mnemo";
    inherit tag;

    # Only what the binary needs at runtime: it is a static-ish Rust binary, no
    # shell scripting, no package manager. bash and coreutils are there so a
    # `kubectl exec` can look around.
    contents = [
      mnemo
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.cacert
    ];

    config = {
      Entrypoint = ["${mnemo}/bin/mnemo"];
      Cmd = ["serve"];
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "PATH=${mnemo}/bin:/bin:/usr/bin"
      ];
      ExposedPorts = {"9152/tcp" = {};};
      WorkingDir = "/";
    };
  }
