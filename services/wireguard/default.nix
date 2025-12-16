{ config, pkgs, ... }:

{
  # 1. Enable the WireGuard module
  networking.wireguard.enable = true;

  # 2. Allow incoming UDP traffic for the WireGuard port
  networking.firewall.allowedUDPPorts = [ 51820 ];

  # 3. Enable IP forwarding and NAT (essential for routing client traffic to the internet)
  networking.ip.forwarding = true;
  networking.nat = {
    enable = true;
    # Replace 'eth0' with your server's primary public-facing network interface
    externalInterface = "eth0"; 
    internalInterfaces = [ "wg0" ];
  };
  
  # 4. Configure the interface (e.g., 'wg0')
  networking.wireguard.interfaces.wg0 = {
    # The IP address and subnet mask of this server *inside* the VPN tunnel.
    # This is the gateway for your clients. /24 is common for a subnet.
    ips = [ "10.0.0.1/24" ];

    # The UDP port WireGuard will listen on.
    listenPort = 51820;

    # Path to the private key file.
    privateKeyFile = "/etc/wireguard/wg0.key";

    # Configure a peer (client) for this server to accept connections from
    peers = [
      {
        # The public key of the first client.
        publicKey = "CLIENT_PUBLIC_KEY_HERE="; # Replace with a client's public key
        
        # The IP address this specific client is allowed to use inside the VPN tunnel.
        # This is a /32 because it's a single host IP.
        allowedIPs = [ "10.0.0.2/32" ]; 
        
        # You can add more peers here:
        # { publicKey = "ANOTHER_CLIENT_KEY="; allowedIPs = [ "10.0.0.3/32" ]; }
      }
    ];
  };
}
