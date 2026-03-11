{
  pkgs,
  lib,
  config,
  ...
}: let
  # ====================================================================
  # LISTE SIMPLE
  # ====================================================================
  wifiNetworksList = [
    "Wifi de Marc"
    "Wifi de Marc 2.4G"
    "AP25G"
    "HKT"
  ];

  # 1. Nettoyage : J'ai ajouté le point "." au remplacement car les variables
  # d'environnement (.env) n'acceptent pas les points dans leurs noms.
  sanitize = str: lib.strings.toLower (builtins.replaceStrings [" " "-" "."] ["_" "_" "_"] str);

  # 2. Règle Stricte
  getSecretName = ssid: "wifi_${sanitize ssid}";
in {
  # ====================================================================
  # 1. GÉNÉRATION DES SECRETS SOPS
  # ====================================================================
  sops.secrets = lib.listToAttrs (map (ssid: {
      name = getSecretName ssid;
      value = {};
    })
    wifiNetworksList);

  # ====================================================================
  # 2. CRÉATION DU FICHIER D'ENVIRONNEMENT (Le template unique)
  # ====================================================================
  # Cela va créer un fichier ressemblant à :
  # wifi_de_marc_psk=motdepasse123
  # ap25g_psk=motdepasse456
  sops.templates."wifi-secrets.env".content = lib.concatStringsSep "\n" (
    map (
      ssid: "${sanitize ssid}_psk=${config.sops.placeholder.${getSecretName ssid}}"
    )
    wifiNetworksList
  );

  # ====================================================================
  # 3. CONFIGURATION NETWORKMANAGER
  # ====================================================================
  networking = {
    useDHCP = lib.mkDefault true;
    hostName = "nixos";
    hostId = "c1ae84e2";
    nameservers = ["8.8.8.8" "8.8.4.4"];
    enableIPv6 = false;

    networkmanager = {
      enable = true;
      wifi.backend = "iwd";

      ensureProfiles = {
        # Indique à NetworkManager où lire les variables d'environnement
        environmentFiles = [config.sops.templates."wifi-secrets.env".path];

        # Génération déclarative des profils
        profiles = lib.listToAttrs (map (ssid: {
            name = ssid;
            value = {
              connection = {
                id = ssid;
                type = "wifi";
                interface-name = "wlan0";
                autoconnect = true;
                # Note: NetworkManager générera l'UUID automatiquement,
                # plus besoin de ta fonction mkUuid !
              };
              wifi = {
                mode = "infrastructure";
                ssid = ssid;
              };
              wifi-security = {
                key-mgmt = "wpa-psk";
                # Le préfixe "$" dit à NetworkManager de lire la variable dans le .env
                psk = "$${sanitize ssid}_psk";
              };
              ipv4 = {method = "auto";};
              ipv6 = {
                method = "auto";
                addr-gen-mode = "default";
              };
            };
          })
          wifiNetworksList);
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;
}
