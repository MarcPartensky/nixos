# services/newt/default.nix
{config, ...}: {
  sops.secrets.newt_env = {
    sopsFile = ../../secrets/common.yml;
    format = "yaml";
    # sops extrait la valeur de la clef newt_env et l'écrit dans un fichier
    # ce fichier sera au format dotenv si la valeur l'est
  };

  services.newt = {
    enable = true;
    environmentFile = config.sops.secrets.newt_env.path;
    settings = {
      endpoint = "https://pangolin.vps.marcpartensky.com";
    };
  };
}
