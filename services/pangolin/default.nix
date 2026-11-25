# services/pangolin/default.nix
{config, pkgs, lib, ...}: {
  nixpkgs.config.permittedInsecurePackages = [
    "pangolin-1.10.3"
  ];

  sops.secrets.pangolin_env = {
    sopsFile = ../../secrets/common.yml;
    format = "yaml";
  };

  services.postgresql.ensureDatabases = [ "pangolin" ];
  services.postgresql.ensureUsers = [
    { name = "pangolin"; ensureDBOwnership = true; }
  ];
  services.postgresql.authentication = lib.mkOverride 10 ''
    local   pangolin    pangolin    md5
    local   all         all         peer
  '';

  services.pangolin = {
    enable = true;
    # "license stub" patch (marc's decision, 2026-10-23): the
    # open-source builds compile server/lib/isLicencedOrSubscribed.ts, a stub hardcoded
    # to `return false` (the oss edition of nixpkgs even removes server/private,
    # which contains the real logic reserved for saas/enterprise builds).
    # Consequence: all the "gated" features - including the private
    # http/ssh resources, needed for nextcloud P2P from NYC - return 403
    # "Please upgrade". We replace the stub with `return true`.
    # To be acknowledged: bypasses Fossorial's commercial gate on our instance.
    # Clean alternative if ever: edition = "enterprise" + a licenseKey.
    package = pkgs.fosrl-pangolin.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace server/lib/isLicencedOrSubscribed.ts \
          --replace-fail 'return false;' 'return true;'
      '';
    });
    baseDomain = "marcpartensky.com";
    dashboardDomain = "pangolin.vps.marcpartensky.com";
    letsEncryptEmail = "marc.partensky@proton.me";
    openFirewall = true;
    environmentFile = config.sops.secrets.pangolin_env.path;
    settings = {
      app = {
        save_logs = true;

      };
      # domains = {
      #   domain1 = {
      #     prefer_wildcard_cert = true;
      #   };
      # };
      server = {
        external_port = 3007;
        internal_port = 3008;
        internal_hostname = "127.0.0.1";
      };
      # Integration API v1 (Bearer key auth, apiKeys table of the
      # dashboard): used by hermes's pangolin MCP. The module then adds
      # the traefik router + the service to localhost:3003, exposed
      # on api.marcpartensky.com (exact Host, cf. the module's int-api-router).
      # Default: disabled.
      flags = {
        enable_integration_api = true;
      };
      postgres = {
        # No password here: the real connection string arrives via
        # the service environment (POSTGRES_CONNECTION_STRING variable of the
        # sops environmentFile above, "pangolin_env" key of
        # secrets/common.yml) and overrides this value on startup. This file
        # goes into the store and the repo (public), so no secret must
        # appear there, even masked.
        connection_string = "postgresql://pangolin@127.0.0.1:5432/pangolin";
      };
    };
  };
}
