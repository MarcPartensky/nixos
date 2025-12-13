{ inputs, pkgs, ... }: {
  services = {
    # Syncthing
    syncthing = {
      enable = true;
      # extraOptions = [
      #   "--home=/home/marc/sync"
      # ];

      # user = "marc";
      # group = "users";
      # dataDir = "/home/marc";
      # configDir = "/home/marc/syncthing";
      settings = {
        option.urAccepted = 1;
        devices = {
          "xiaomi12" ={
      	    id = "PEAKD4W-MDXJTZQ-C5WZWXZ-AW72EK3-WLFLM2L-A2GVBEM-HOB62UJ-BNHUQAB";
            # autoAcceptFolders = true;
      	  };
        };
      # 	folders."Camera" = {
      # 	  path = "/home/marc/sync/Camera";
      # 	  devices = [ "xiaomi12" ];
      # 	  type = "sendreceive";
      # 	  # one of "sendreceive", "sendonly", "receiveonly", "receiveencrypted"
      # 	};
      # 	folders."Personal" = {
      # 	  path = "/home/marc/sync/Personal";
      # 	  devices = [ "xiaomi12" ];
      # 	  type = "sendreceive";
      # 	};
      };
      guiAddress = "127.0.0.1:8384";
      # openDefaultPorts = true;
    };
  };
}
