{ pkgs, ... }: {
  config.services.postgresql = {
    enable = true;
    ensureDatabases = [ "nextcloud" "vaultwarden" ];
    ensureUsers = [ "nextcloud" "vaultwarden" ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust
      
      # IPv4 localhost
      host all all 127.0.0.1/32 trust

      # IPv6 localhost
      host all all ::1/128 trust
    '';
      # Script SQL initial (doit être un fichier réel)
    initialScript = pkgs.writeText "vaultwarden-init.sql" ''
      CREATE USER vaultwarden WITH LOGIN PASSWORD 'vaultwarden';
      CREATE USER root WITH LOGIN PASSWORD 'rootpassword';
      GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
      GRANT ALL PRIVILEGES ON DATABASE root TO vaultwarden;
    '';
  };
}
