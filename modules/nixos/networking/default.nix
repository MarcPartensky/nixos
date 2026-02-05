{
  pkgs,
  lib,
  config,
  ...
}: let
  # ====================================================================
  # CONFIGURATION DES RÉSEAUX
  # Ajoute tes réseaux ici. La clé est le SSID (nom du wifi).
  # ====================================================================
  wifiNetworksList = [
    "Wifi de Marc"
    "Wifi AP25G"
    "Wifi HKT"
  ];

  # ====================================================================
  # MAGIE NOIRE (Génération automatique)
  # ====================================================================

  # 1. Fonction pour nettoyer le nom (ex: "Wifi de Marc" -> "wifi_de_marc")
  sanitize = str: lib.strings.toLower (builtins.replaceStrings [" " "-"] ["_" "_"] str);

  # 2. Fonction pour générer un UUID stable à partir du SSID (Hash MD5)
  # On découpe le hash pour qu'il ressemble à un UUID : 8-4-4-4-12
  mkUuid = str: let
    hash = builtins.hashString "md5" str;
  in "${builtins.substring 0 8 hash}-${builtins.substring 8 4 hash}-${builtins.substring 12 4 hash}-${builtins.substring 16 4 hash}-${builtins.substring 20 12 hash}";

  # 3. Fonction qui construit la config complète pour un SSID
  createNetworkConfig = ssid: let
    cleanName = sanitize ssid;
    uuid = mkUuid ssid;
    secretName = "${cleanName}"; # On suppose que la clé sops s'appelle comme ça
  in {
    name = "wifi-${builtins.replaceStrings [" "] ["-"] ssid}.nmconnection";
    value = {
      mode = "0600";
      owner = "root";
      path = "/etc/NetworkManager/system-connections/${ssid}.nmconnection";
      content = lib.generators.toINI {} {
        connection = {
          id = ssid;
          uuid = uuid;
          type = "wifi";
          autoconnect = true;
          interface-name = "wlan0";
          permissions = "";
        };
        wifi = {
          mode = "infrastructure";
          ssid = ssid;
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          # On va chercher le secret sops automatiquement basé sur le nom
          psk = config.sops.placeholder.${secretName};
          "psk-flags" = "0";
        };
        ipv4 = {method = "auto";};
        ipv6 = {
          method = "auto";
          addr-gen-mode = "default";
        };
      };
    };
  };

  # On transforme la liste simple en format attendu par sops et nm
  wifiConfigs = lib.listToAttrs (map (ssid: {
      name = ssid;
      value = createNetworkConfig ssid;
    })
    wifiNetworksList);
in {
  sops.secrets = lib.listToAttrs (map (ssid: {
      name = "${sanitize ssid}";
      value = {};
    })
    wifiNetworksList);

  # 2. Génération des fichiers de config NetworkManager
  sops.templates = lib.mapAttrs (n: v: v.value) (lib.listToAttrs (map (ssid: {
      name = "wifi-${sanitize ssid}"; # Nom unique pour le template
      value = createNetworkConfig ssid;
    })
    wifiNetworksList));

  # 3. Configuration système standard
  networking = {
    useDHCP = lib.mkDefault true;
    hostName = "nixos";
    hostId = "c1ae84e2";
    nameservers = ["8.8.8.8" "8.8.4.4"];
    enableIPv6 = false;

    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
      # Plus besoin de ensureProfiles ni de wireless.networks !
      # Tout est géré par les fichiers générés dans /etc/NetworkManager/system-connections/
    };

    wireless.iwd = {
      enable = true;
      settings = {
        IPv6.Enabled = true;
        Settings.AutoConnect = true;
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;
}
