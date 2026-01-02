{ pkgs, ... }:
{
  # Installation du paquet
  environment.systemPackages = [ pkgs.newt-connector ];

  # Configuration du service client
  services.newt = {
    enable = true;
    # Fichier contenant votre jeton d'authentification
    environmentFile = "/var/lib/newt/secret";
    # Configuration des tunnels
    settings = {
      endpoint = "pangolin.marcpartensky.com";
      # id = "8yfsghj438a20ol";
      # tunnels = [
      #   {
      #     name = "vaultwarden-local";
      #     proto = "http";
      #     port = 8083; # Le port local de votre Vaultwarden
      #     subdomain = "vault-portable"; # Deviendra vault-portable.marcpartensky.com
      #   }
      # ];
    };
  };
}
