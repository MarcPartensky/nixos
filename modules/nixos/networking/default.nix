{
  pkgs,
  lib,
  config,
  ...
}: let
  # ====================================================================
  # SIMPLE LIST
  # ====================================================================
  wifiNetworksList = [
    "Wifi de Marc"
    "Wifi de Marc 2.4G"
    "AP25G"
    "HKT"
  ];

  # 1. Cleanup: I added the "." to the replacement because environment
  # variables (.env) do not accept dots in their names.
  sanitize = str: lib.strings.toLower (builtins.replaceStrings [" " "-" "."] ["_" "_" "_"] str);

  # 2. Strict Rule
  getSecretName = ssid: "wifi_${sanitize ssid}";
in {
  # ====================================================================
  # 1. GENERATION OF SOPS SECRETS
  # ====================================================================
  sops.secrets = lib.listToAttrs (map (ssid: {
      name = getSecretName ssid;
      value = {};
    })
    wifiNetworksList);

  # ====================================================================
  # 2. CREATION OF THE ENVIRONMENT FILE (The single template)
  # ====================================================================
  # This will create a file looking like:
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
    # hostName = "nixos";
    hostId = "c1ae84e2";
    nameservers = ["8.8.8.8" "8.8.4.4"];
    enableIPv6 = false;

    networkmanager = {
      enable = true;
      wifi.backend = "iwd";

      ensureProfiles = {
        # Tell NetworkManager where to read the environment variables
        environmentFiles = [config.sops.templates."wifi-secrets.env".path];

        # Declarative generation of profiles
        profiles = lib.listToAttrs (map (ssid: {
            name = ssid;
            value = {
              connection = {
                id = ssid;
                type = "wifi";
                interface-name = "wlan0";
                autoconnect = true;
                # Note: NetworkManager will generate the UUID automatically,
                # no need for your mkUuid function anymore!
              };
              wifi = {
                mode = "infrastructure";
                ssid = ssid;
              };
              wifi-security = {
                key-mgmt = "wpa-psk";
                # The "$" prefix tells NetworkManager to read the variable from the .env
                psk = "$${sanitize ssid}_psk";
              };
              ipv4 = {method = "auto";};
              ipv6 = {
                # This module declares `networking.enableIPv6 = false`, but the
                # profile used to bring IPv6 back on wlan0 (method = "auto",
                # which is also NetworkManager's own default), while nixpkgs
                # writes NO IPv6 firewall table when the option is false (its
                # ip6tables rules are tied to it). The result is a host with a
                # PUBLIC IPv6 address and no filter at all on it: measured on
                # the laptop 2026-11-25, llama-swap on *:8080 answered 200 over
                # [2603:7000:...] from tower while the same port is dropped on
                # the LAN, and sshd (AddressFamily inet, derived from the same
                # option) refused TCP on every port of that address while the
                # host answered pings in 21 ms -> read as "sshd is down".
                # The option is the single source of truth: a host that really
                # wants IPv6 forces it true (tower does, for yggdrasil) and
                # keeps its IPv6; the others get none, instead of a half state.
                method = if config.networking.enableIPv6 then "auto" else "disabled";
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
