# services/newt/default.nix
{config, ...}: {
  sops.secrets.newt_env = {
    # format du fichier sops : NEWT_ID=xxx\nNEWT_SECRET=yyy
    format = "dotenv";
    # ou si tu stockes dans ton yaml sops habituel, adapte le path:
    # sopsFile = ../../secrets/tower.yaml;
  };

  services.newt = {
    enable = true;
    environmentFile = config.sops.secrets.newt_env.path;
    settings = {
      endpoint = "https://pangolin.vps.marcpartensky.com";
    };
  };
}
