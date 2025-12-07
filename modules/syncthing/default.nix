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
        option.urAccepted = 1;
        devices = {
          "xiaomi12" ={
	    id = "PEAKD4W-MDXJTZQ-C5WZWXZ-AW72EK3-WLFLM2L-A2GVBEM-HOB62UJ-BNHUQAB";
	    autoAcceptFolders = true;
	  };
        };
      	folders."marc" = {
	  path = "/home/marc/synthing";
	  devices = [ "xiaomi12" ];
	  type = "sendreceive";
	  # one of "sendreceive", "sendonly", "receiveonly", "receiveencrypted"
	};
      };
      guiAddress = "127.0.0.1:8384";
      # openDefaultPorts = true;
    };
  };
}
