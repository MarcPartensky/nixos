{
  config,
  pkgs,
  ...
}: {
  # Configuration du serveur Eternal Terminal
  services.eternal-terminal = {
    enable = true;

    # Le port par défaut est 2022, tu peux le changer si besoin
    port = 2022;

    # Options facultatives (décommenter pour utiliser) :
    # verbosity = 0;
    # silent = false;
    # logSize = 20971520;
  };

  # TRÈS IMPORTANT : Ouvrir le port dans le pare-feu pour pouvoir s'y connecter
  networking.firewall.allowedTCPPorts = [config.services.eternal-terminal.port];
}
