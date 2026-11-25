{ config, pkgs, ... }:
{
  services.tor = {
    enable = true; 

    # Disable GeoIP to prevent the Tor client from estimating the locations of Tor nodes it connects to
    enableGeoIP = false;

    # Enable Torsocks for transparent proxying of applications through Tor
    torsocks.enable = true;

    # Enable the Tor client
    client = {
      enable = true;
    };

    # Enable and configure the Tor relay
    relay = {
      enable = true;
      role = "relay";  # Set the relay role (e.g., "relay", "bridge")
    };

    # Configure Tor settings
    settings = {
      # Nickname = "YourNickname";  
      # ContactInfo = "your-email@example.com"; 

      # Bandwidth settings
      MaxAdvertisedBandwidth = "100 MB";  
      BandWidthRate = "50 MB";  
      RelayBandwidthRate = "50 MB";  
      RelayBandwidthBurst = "100 MB"; 

      # Restrict exit nodes to a specific country (use the appropriate country code)
      ExitNodes = "{ch} StrictNodes 1";  
      
      # Reject all exit traffic
      ExitPolicy = "reject *:*";  

      # Performance and security settings
      CookieAuthentication = true;  
      AvoidDiskWrites = 1; 
      HardwareAccel = 1;  
      SafeLogging = 1; 
      NumCPUs = 3;   

      # Network settings
      ORPort = [443];
    };
  };

# snowflake-proxy: PERMANENTLY REMOVED on 13/11/2026, do not add it back.
# Measured: 1.6 cores continuously, 34% of a core on average since boot
# (2 h 27 of CPU per boot), for a volunteer service on a machine already under
# pressure. Marc never asked for this proxy: it came bundled in
# commit f1a63ca of 02/01/2026 (module "tor" written in one go, relay + snowflake),
# with a simple comment "Safe to run". No tradeoff, no measurement, and
# nobody touched it for ten months. If marc ever explicitly asks
# to relay, cap it: CPUQuota = "50%" on snowflake-proxy.service, never
# more. And reconsider the Tor relay above, which does not even publish.

}

