{
  pkgs,
  lib,
  config,
  ...
}: let
  # ====================================================================
  # LISTE SIMPLE (Ce que tu voulais)
  # ====================================================================
  wifiNetworksList = [
    "Wifi de Marc"
    "Wifi de Marc 2.4G"
    "AP25G"
    "HKT"
  ];

  # 1. Nettoyage : tout en minuscule, remplace espaces/tirets/points par "_"
  sanitize = str: lib.strings.toLower (builtins.replaceStrings [" " "-"] ["_" "_"] str);

  # 2. Règle Stricte : Le secret s'appelle TOUJOURS "wifi_" + nom nettoyé
  getSecretName = ssid: "wifi_${sanitize ssid}";

  # 3. UUID stable basé sur le hash du nom
  mkUuid = str: let
    hash = builtins.hashString "md5" str;
  in "${builtins.substring 0 8 hash}-${builtins.substring 8 4 hash}-${builtins.substring 12 4 hash}-${builtins.substring 16 4 hash}-${builtins.substring 20 12 hash}";

  createNetworkConfig = ssid: let
    secretName = getSecretName ssid;
  in {
    name = "wifi-${sanitize ssid}.nmconnection";
    value = {
      mode = "0600";
      owner = "root";
      path = "/etc/NetworkManager/system-connections/${ssid}.nmconnection";
      content = lib.generators.toINI {} {
        connection = {
          id = ssid;
          uuid = mkUuid ssid;
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
in {
  # Génération des secrets attendus (wifi_ap25g, wifi_wifi_de_marc, etc.)
  sops.secrets = lib.listToAttrs (map (ssid: {
      name = getSecretName ssid;
      value = {};
    })
    wifiNetworksList);

  # Génération des fichiers NetworkManager
  sops.templates = lib.mapAttrs (n: v: v.value) (lib.listToAttrs (map (ssid: {
      name = "wifi-${sanitize ssid}";
      value = createNetworkConfig ssid;
    })
    wifiNetworksList));

  networking = {
    useDHCP = lib.mkDefault true;
    hostName = "nixos";
    hostId = "c1ae84e2";
    nameservers = ["8.8.8.8" "8.8.4.4"];
    enableIPv6 = false;

    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };
  };

  services.gnome.gnome-keyring.enable = true;
}
