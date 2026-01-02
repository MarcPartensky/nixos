{ config, pkgs, inputs, ... }:
let
  pangolin = inputs.unstable.fosrl-pangolin;
in
{

  networking.firewall = {
    enable = true;

    allowedTCPPorts = [
      # --- Web & Reverse Proxy ---
      80   # HTTP (ACME & Redirect)
      443  # HTTPS (Webmail & Management)

      # --- Stalwart Mail Server ---
      25   # SMTP (Réception de mails)
      465  # SMTP Submissions (Envoi client)
      993  # IMAP sécurisé (Lecture client)
      8090 # stalwart admin


      # --- Vos autres services ---
      8080 8081 8082 8083 # Pangolin / Apps
      5432                # PostgreSQL
      3000 3002           # Apps Web (ex: Grafana, Node)
    ];
  };


  # networking.wireguard.enable = true;
  # networking.wireguard.interfaces = {
  #   wg0 = {
  #     privateKey = "UEKfQ6iKyIWlbkPuD60sqLt1BZ3ceQYUy44PZMczqHw=";       # server or client private key
  #     address = [ "10.0.0.1/24" ];                 # your WG subnet
  #     listenPort = 51820;                           # optional, default 51820
  #     peers = [
  #       {
  #         publicKey = "Jlur6sLameyTQJHdTGcEp9oT3bfCplgCNuSxNJwlzz0=";
  #         allowedIPs = [ "10.0.0.2/32" ];           # peer address
  #         endpoint = "1.2.3.4:51820";               # optional
  #         persistentKeepalive = 25;                 # optional, for NAT
  #       }
  #     ];
  #   };
  # };
}
