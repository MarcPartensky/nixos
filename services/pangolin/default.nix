# services/pangolin/default.nix
{config, ...}: {
  nixpkgs.config.permittedInsecurePackages = [
    "pangolin-1.10.3"
  ];

  sops.secrets.pangolin_env = {
    # sopsFile = ../../secrets/vps.yaml;  # si pas le fichier par défaut
  };

  services.pangolin = {
    enable = true;
    baseDomain = "marcpartensky.com";
    dashboardDomain = "pangolin.marcpartensky.com";
    letsEncryptEmail = "marc.partensky@proton.me";
    openFirewall = true;
    environmentFile = config.sops.secrets.pangolin_env.path;
  };
}
