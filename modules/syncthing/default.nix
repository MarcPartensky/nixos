{ inputs, pkgs, ... }: {
  services = {
    # Syncthing
    syncthing = {
      enable = true;
      # user = "marc";
      # group = "users";
      # dataDir = "/home/marc";
      # configDir = "/home/marc/syncthing";
      settings = {
        devices = {
          xiaomi12.id = "PEAKD4W-MDXJTZQ-C5WZWXZ-AW72EK3-WLFLM2L-A2GVBEM-HOB62UJ-BNHUQAB";
        };
      	folders."marc" = {
	  path = "/home/marc/synthing";
	  devices = [ "xiaomi12" ];
	};
      };
      guiAddress = "127.0.0.1:8384";
      # openDefaultPorts = true;
    };
  };
}
