{lib, ...}: {
  # systemd.services.rqbit.serviceConfig.RestrictAddressFamilies = lib.mkForce [
  #   "AF_INET"
  #   "AF_INET6"
  #   "AF_UNIX"
  #   "AF_NETLINK"
  # ];
  services.rqbit = {
    enable = true;
    httpPort = 3030;
    downloadDir = "/home/marc/downloads/";
    user = "marc";
  };
}
