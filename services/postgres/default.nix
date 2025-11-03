{ pkgs, ... }: {
  config.services.postgresql = {
    enable = true;
    ensureDatabases = [ "nextcloud" ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust
    '';
    initialScript = ''
      CREATE USER vaultwarden WITH PASSWORD 'vaultwarden';
      CREATE DATABASE vaultwarden OWNER vaultwarden;
    '';
  };
}
