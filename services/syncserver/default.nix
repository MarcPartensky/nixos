{ config, pkgs, ... }:

{
  # 1. Configuration de PostgreSQL (inspirée de ta config Vaultwarden)
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "firefoxsync" ];
    ensureUsers = [
      {
        name = "firefoxsync";
        ensureDBOwnership = true;
      }
    ];
  };

  # 2. Configuration de Firefox Syncserver
  services.firefox-syncserver = {
    enable = true;
    
    # Utilisation du mode singleNode pour la simplicité
    # singleNode = {
    #   enable = true;
    #   hostname = "sync.marcpartensky.com";
    #   url = "https://sync.marcpartensky.com";
    #   enableNginx = true;
    # };

    singleNode = {
      enable = true;
      hostname = "localhost"; 
      url = "http://localhost:5000"; # On passe en HTTP pour le test
      enableNginx = false;           # Pas besoin de reverse proxy pour un test local
    };

    # Configuration de la base de données
    # On pointe vers le socket local de PostgreSQL
    database = {
      createLocally = false; # On gère la DB manuellement ci-dessus
      user = "firefoxsync";
      name = "firefoxsync";
      host = "/run/postgresql"; 
    };

    # Chemin vers le secret (doit contenir une chaîne aléatoire)
    secrets = "/var/lib/firefox-syncserver/secrets";

    logLevel = "info";
  };

  # 3. Sécurité : Création automatique du répertoire et gestion des droits
  systemd.services.firefox-syncserver = {
    preStart = ''
      mkdir -p /var/lib/firefox-syncserver
      if [ ! -f /var/lib/firefox-syncserver/secrets ]; then
        head -c 32 /dev/urandom | base64 > /var/lib/firefox-syncserver/secrets
      fi
      chown -R firefox-syncserver:firefox-syncserver /var/lib/firefox-syncserver
    '';
    serviceConfig.StateDirectory = "firefox-syncserver";
  };
}
