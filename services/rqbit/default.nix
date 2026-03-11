{...}: {
  services.rqbit = {
    enable = true;
    httpPort = 3030;
    downloadDir = "/home/marc/downloads/";
  };
}
