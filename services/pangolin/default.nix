# services/pangolin/default.nix
{config, pkgs, ...}: {
  nixpkgs.config.permittedInsecurePackages = [
    "pangolin-1.10.3"
  ];

  sops.secrets.pangolin_env = {
    sopsFile = ../../secrets/common.yml;
  };

  services.pangolin = {
    enable = true;
    package = pkgs.fosrl-pangolin;
    baseDomain = "marcpartensky.com";
    dashboardDomain = "pangolin.marcpartensky.com";
    letsEncryptEmail = "marc.partensky@proton.me";
    openFirewall = true;
    environmentFile = config.sops.secrets.pangolin_env.path;
  };
}
