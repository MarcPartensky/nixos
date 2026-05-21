# hosts/macbook/services/wireguard/default.nix
{ config, pkgs, ... }: {

  sops.secrets."wireguard/mac_private_key" = {
    owner = "marc";  # ton username macOS
    mode = "0400";
  };

  networking.wg-quick.interfaces.wg1 = {
    address = [ "10.100.0.2/24" ];
    dns = [ "1.1.1.1" ];
    privateKeyFile = config.sops.secrets."wireguard/mac_private_key".path;

    peers = [
      {
        publicKey = "dsOBj2AfqF7YQ1JTGfYjlFse5sFZzwudOBiEMDLAzhU=";  # wg show wg1 public-key sur le VPS
        endpoint = "104.129.12.158:51821";
        allowedIPs = [ "0.0.0.0/0" "::/0" ];
        persistentKeepalive = 25;
      }
    ];
  };

  environment.systemPackages = with pkgs; [
    wireguard-tools
    wireguard-go   # backend userspace requis sur macOS
  ];
}
