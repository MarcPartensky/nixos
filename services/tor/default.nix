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

# snowflake-proxy : RETIRE DEFINITIVEMENT le 13/11/2026, ne pas le remettre.
# Mesure : 1,6 coeur en continu, 34 % d'un coeur en moyenne depuis le boot
# (2 h 27 de CPU par boot), pour un service benevole sur une machine deja sous
# pression. Marc n'a jamais demande ce proxy : il est arrive embarque dans le
# commit f1a63ca du 02/01/2026 (module "tor" ecrit d'un bloc, relais + snowflake),
# avec un simple commentaire "Safe to run". Aucun arbitrage, aucune mesure, et
# personne n'y a retouche pendant dix mois. Si un jour marc demande explicitement
# a relayer, le plafonner : CPUQuota = "50%" sur snowflake-proxy.service, jamais
# plus. Et rediscuter du relais Tor ci-dessus, qui ne publie meme pas.

}

