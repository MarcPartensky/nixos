{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
    ../../modules/nixos/herdr
  ];

  # Sessions hermes lancees par marc (panes herdr, HERMES_HOME partage, cf
  # users/marc/home.nix) : elles ecrivent dans /var/lib/hermes/.hermes. Le
  # groupe hermes (users.nix) plus les chmod g+rw du module hermes couvrent
  # l'existant ; ces ACL garantissent la traversee de /var/lib/hermes (2770) et
  # que les fichiers crees par marc restent lisibles par le service.
  # Pattern repris de services/firefox-mcp et amazon-mcp.
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "a /var/lib/hermes/.hermes - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
    "a /var/lib/hermes/.hermes/plugins - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
  ];

  boot.kernelParams = ["panic=10"];
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  boot.kernelModules = ["vkms"];
  boot.initrd.secrets."/etc/secrets/zfs-root.key" = "/etc/secrets/zfs-root.key";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      2022
      8083 # Pangolin / Apps
      8050
      5432 # PostgreSQL
      6080 # noVNC (client VNC web de la session niri)
      8089 # rustguac
      8443 # KasmVNC
      8200 # Vault
      21115 21116 21118 # RustDesk
    ];
  };

  users.users.hermes.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
  ];

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;

  services.hermes.enableMatrixToken = true;
  services.hermes.enableDiscordToken = true;

  # ========================================================================
  # RUSTGUAC - Gateway Rust (remplace Guacamole Java)
  # ========================================================================
  services.rustguac = {
    enable = true;
    host = "127.0.0.1";
    port = 8089;
    guacd = { host = "127.0.0.1"; port = 4822; tls = true; };
    vault = {
      address = "http://127.0.0.1:8200";
      token = "/run/secrets/vault-rustguac-root-token";
      mountPath = "secret";
      connectionsPath = "rustguac/connections";
    };
    oidc = {
      issuerUrl = "https://auth.example.com"; # TODO: remplacer par ton OIDC
      clientId = "rustguac";
      clientSecret = "/run/secrets/rustguac-oidc-client-secret";
      redirectUrl = "https://guac.example.com/api/oidc/callback";
      scopes = [ "openid" "profile" "email" "groups" ];
      usernameClaim = "email";
      groupsClaim = "groups";
    };
    recording = {
      enable = true;
      storagePath = "/var/lib/rustguac/recordings";
      maxSize = "10G";
      maxAge = "30d";
    };
    rateLimit = { enabled = true; requestsPerMinute = 120; };
  };

  # ========================================================================
  # KASMVNC - Bureau personnel Wayland haute perf (LXQt + kwin_wayland)
  # ========================================================================
  services.kasmvnc = {
    enable = true;
    user = "marc";
    display = ":1";
    geometry = "1920x1080";
    port = 8443;
    tls = {
      certFile = "/run/secrets/kasmvnc-cert-pem";
      keyFile = "/run/secrets/kasmvnc-key-pem";
    };
    passwordFile = "/home/marc/.kasmpasswd";
    desktop = "lxqt-wayland";
  };

  # ========================================================================
  # VAULT - Dev mode pour rustguac (stockage connexions)
  # ========================================================================
  services.vault-rustguac = {
    enable = true;
    mode = "dev";
    address = "127.0.0.1";
    port = 8200;
    devRootToken = "/run/secrets/vault-rustguac-root-token";
    ui = true;
  };

  # ========================================================================
  # RUSTDESK - Serveur P2P (hbbs + hbbr)
  # ========================================================================
  services.rustdesk = {
    enable = true;
    hbbs = { enable = true; port = 21115; };
    hbbr = { enable = true; port = 21116; apiPort = 21118; };
    openFirewall = true;
  };

  # ========================================================================
  # NGINX - Reverse proxy avec ACME pour les deux services
  # ========================================================================
  services.nginx.rustguac = {
    enable = true;
    domain = "guac.example.com"; # TODO: ton domaine
    upstream = "http://127.0.0.1:8089";
    acme = true;
  };

  services.nginx.kasmvnc = {
    enable = true;
    domain = "kasm.example.com"; # TODO: ton domaine
    upstream = "https://127.0.0.1:8443";
    acme = true;
  };

  # ========================================================================
  # SECRETS (sops-nix)
  # ========================================================================
  sops.secrets = {
    vault-rustguac-root-token = {
      sopsFile = ../../secrets/tower.yml;
      owner = "root";
      mode = "0400";
    };
    rustguac-oidc-client-secret = {
      sopsFile = ../../secrets/tower.yml;
      owner = "root";
      mode = "0400";
    };
    kasmvnc-cert-pem = {
      sopsFile = ../../secrets/tower.yml;
      owner = "root";
      mode = "0400";
    };
    kasmvnc-key-pem = {
      sopsFile = ../../secrets/tower.yml;
      owner = "root";
      mode = "0400";
    };
    "pangolin/api_key" = {
      sopsFile = ../../secrets/common.yml;
    };
  };

  # User lingering pour KasmVNC systemd user service
  users.users.marc.linger = true;
}