{ pkgs, ... }: {
  config.services.postgresql = {
    enable = true;
    ensureDatabases = [ "nextcloud" ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust
    '';
      # Script SQL initial (doit être un fichier réel)
    initialScript = pkgs.writeText "vaultwarden-init.sql" ''
      CREATE USER vaultwarden WITH LOGIN PASSWORD 'vaultwarden';
      GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
    '';
  };
}
