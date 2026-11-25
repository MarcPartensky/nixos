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

      # transient user named "oxicloud" -> peer auth on the PG socket OK
      DynamicUser = true;
      User = "oxicloud";
      StateDirectory = "oxicloud";
      WorkingDirectory = "/var/lib/oxicloud";

      # hardening
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      Restart = "on-failure";
    };
  };

  sops.secrets.oxicloud_env = { };
}
