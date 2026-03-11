{pkgs, ...}: {
  services.rqbit = {
    enable = true;
    httpPort = 3030;
  };
}
