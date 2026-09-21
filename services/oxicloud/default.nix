{ config, pkgs, lib, ... }:
{
  services.postgresql = {
    ensureDatabases = [ "oxicloud" ];
    ensureUsers = [{
      name = "oxicloud";
      ensureDBOwnership = true;
    }];
  };

  systemd.services.oxicloud = {
    description = "OxiCloud";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "postgresql.service" ];
    requires = [ "postgresql.service" ];

    serviceConfig = {
      ExecStart = "${pkgs.oxicloud}/bin/oxicloud";
      EnvironmentFile = config.sops.secrets.oxicloud_env.path;

      # user transient nommé "oxicloud" -> auth peer sur le socket PG OK
      DynamicUser = true;
      User = "oxicloud";
      StateDirectory = "oxicloud";
      WorkingDirectory = "/var/lib/oxicloud";

      # durcissement
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      Restart = "on-failure";
    };
  };

  sops.secrets.oxicloud_env = { };
}
