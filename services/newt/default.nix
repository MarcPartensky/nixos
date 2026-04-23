# services/newt/default.nix
{
  config,
  pkgs,
  ...
}: {
  sops.secrets.newt_env = {
    sopsFile = ../../secrets/common.yml;
    # format = "yaml";
    # key = "newt_env";

    # sops extrait la valeur de la clef newt_env et l'écrit dans un fichier
    # ce fichier sera au format dotenv si la valeur l'est
  };

  services.newt = {
    enable = true;
    environmentFile = config.sops.secrets.newt_env.path;
    # settings = {
    #   endpoint = "https://pangolin.vps.marcpartensky.com";
    #   id = "4y2rxynfoiseqon";
    #   # secret = config.sops.secrets.newt_env.value;
    # };
  };

  # systemd.services.newt = {
  #   enable = true;
  #   wantedBy = ["multi-user.target"];
  #   after = ["network-online.target"];
  #   serviceConfig = {
  #     ExecStart = "${pkgs.fosrl-newt}/bin/newt --id test --secret i9q2wx1heguo1ix823r9hwm51bnv30d30v7b2plx5pvsehb3 --endpoint https://pangolin.vps.marcpartensky.com";
  #     Restart = "always";
  #   };
  # };
}
