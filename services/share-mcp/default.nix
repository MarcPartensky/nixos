# services/share-mcp/default.nix
# MCP `share` (code in ./server.py): publishes a file into Garage's public
# bucket, creates the Shlink short link on it, and optionally a 4-character
# x.gd facade. A single call does all three legs.
#
# Split with services/garage: Garage carries the capability (`web` section of
# garage.toml, `public` bucket marked website, health placeholder). This module
# carries the PUBLIC face of that capability: the Pangolin resource
# files.marcpartensky.com and the tooling that consumes it.
#
# SSO deliberately DISABLED on files.marcpartensky.com: the domain serves as
# the target of the short links, so a 302 to Zitadel would break all the
# shared links. Accepted trade-off: any object in the `public` bucket is readable by
# whoever knows its URL. The artifacts and photos-* buckets are not marked
# website, so Garage keeps refusing them anonymously on this same endpoint.
{self, pkgs, config, ...}: let
  # Port of the Garage web endpoint (declared in services/garage).
  webPort = 3902;

  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this conf, and no longer rebuilt on every host eval.
  share-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.share-mcp;

  # Wrapper: the S3 credentials are generated at activation by
  # garage-bootstrap and live in /var/lib/garage/s3-key.env (0400 hermes),
  # never in the store. The `aws` binary comes from here, not from the config.
  # Manual debug (keep stdin open, an EOF kills the request):
  #   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
  #     | /nix/store/.../bin/share-mcp-hermes
  wrapper = pkgs.writeShellScript "share-mcp-hermes" ''
    set -euo pipefail
    # shellcheck disable=SC1091
    . /var/lib/garage/s3-key.env
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    export PATH=${pkgs.awscli2}/bin:$PATH
    exec ${share-mcp}/bin/share-mcp
  '';
in {
  environment.systemPackages = [share-mcp];

  services.hermes-agent.mcpServers.share = {
    command = "${wrapper}";
    args = [];
    env = {
      SHARE_BUCKET = "public";
      # Public domain serving the bucket (path-style /<bucket>/<key>).
      SHARE_PUBLIC_BASE = "https://files.marcpartensky.com/public";
      SHARE_S3_ENDPOINT = "http://127.0.0.1:3900";
      SHARE_ALLOW_WRITES = "1";
      SHLINK_URL = "http://127.0.0.1:8097";
      SHLINK_API_KEY_FILE = config.sops.secrets.shlink_api_key.path;
    };
    # File uploads exceed the 60 s of the other MCP servers.
    timeout = 900;
  };

  # Pangolin public resource: files.marcpartensky.com -> Garage web
  # endpoint. `proxy-resources` + `protocol` schema (the one that works on this
  # controller). Healthcheck on the placeholder deposited by the bootstrap:
  # Garage answers 404 on the root of a bucket without index.html.
  services.newt.blueprint.proxy-resources.files = {
    name = "files";
    protocol = "http";
    full-domain = "files.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = webPort;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = webPort;
          path = "/public/_health.txt";
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

  # Guard rail: the web endpoint must never be opened to the LAN, it is only
  # reachable through the loopback (MCP, tests) and through newt (Pangolin).
  assertions = [
    {
      assertion = !(builtins.elem webPort
        config.networking.firewall.allowedTCPPorts);
      message = "share-mcp: Garage port ${toString webPort} must not be opened to the firewall.";
    }
  ];
}
