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
    # package = pkgs.fosrl-pangolin;
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
      postgres = {
        connection_string =
          "postgresql://pangolin:MarcPangolin44@127.0.0.1:5432/pangolin";
      };
    };
  };
}
