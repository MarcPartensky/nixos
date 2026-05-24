{config, lib, pkgs, ... }:

let cfg = config.services.droplify;
in {
  options.services.droplify = {
    enable  = lib.mkEnableOption "droplify";
    port    = lib.mkOption { type = lib.types.port;  default = 8080; };
    domain  = lib.mkOption { type = lib.types.str; };
    dataDir = lib.mkOption { type = lib.types.str;   default = "/var/lib/droplify"; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.droplify = {
      description = "droplify HTML hosting";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ];

      environment = {
        DATA_DIR = cfg.dataDir;
        BASE_URL = "https://${cfg.domain}";
        PORT     = toString cfg.port;
      };

      serviceConfig = {
        ExecStart       = "${pkgs.python3}/bin/python3 ${./droplify.py}";
        StateDirectory  = "droplify";
        DynamicUser     = true;
        Restart         = "on-failure";
        PrivateTmp      = true;
        NoNewPrivileges = true;
      };
    };
  };
}
