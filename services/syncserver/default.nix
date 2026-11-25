{ config, pkgs, ... }:

{
  # 1. PostgreSQL configuration (inspired by your Vaultwarden config)
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

  # 2. Firefox Syncserver configuration
  services.firefox-syncserver = {
    enable = true;
    
    # Using singleNode mode for simplicity
    # singleNode = {
    #   enable = true;
    #   hostname = "sync.marcpartensky.com";
    #   url = "https://sync.marcpartensky.com";
    #   enableNginx = true;
    # };

    singleNode = {
      enable = true;
      hostname = "localhost"; 
      url = "http://localhost:5000"; # We switch to HTTP for the test
      enableNginx = false;           # No reverse proxy needed for a local test
    };

    # Database configuration
    # We point to the local PostgreSQL socket
    database = {
      createLocally = false; # We handle the DB manually above
      user = "firefoxsync";
      name = "firefoxsync";
      host = "/run/postgresql"; 
    };

    # Path to the secret (must contain a random string)
    secrets = "/var/lib/firefox-syncserver/secrets";

    logLevel = "info";
  };

  # 3. Security: Automatic directory creation and permission management
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
