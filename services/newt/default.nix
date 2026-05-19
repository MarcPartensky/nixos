{
  config,
  pkgs,
  lib,
  ...
}: {
  sops.secrets.newt_env = {
    sopsFile = ../../secrets/common.yml;
    mode = "0440";
  };

  services.newt = {
    enable = true;
    environmentFile = config.sops.secrets.newt_env.path;
    # settings = {
    #   endpoint = "https://pangolin.vps.marcpartensky.com";
    #   id = "4y2rxynfoiseqon";
    # };
  };

  # systemd.services.newt.serviceConfig = {
  #   DynamicUser = lib.mkForce false;
  #   PrivateUsers = lib.mkForce false;
  #   ProtectHome = lib.mkForce false;
  #   ExecStart = lib.mkForce (pkgs.writeShellScript "newt-start" ''
  #     set -a
  #     source ${config.sops.secrets.newt_env.path}
  #     set +a
  #     exec ${pkgs.fosrl-newt}/bin/newt \
  #       -endpoint="$PANGOLIN_ENDPOINT" \
  #       -id="$NEWT_ID" \
  #       -secret="$NEWT_SECRET"
  #   '');
  # };
}
