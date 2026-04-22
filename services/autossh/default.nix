{config, ...}: {
  services.autossh = {
    sessions = [
      {
        name = "rack-tunnel";
        user = "marc";
        extraArguments = "-N -R 2222:localhost:22 root@marcpartensky.com";
      }
    ];
  };
}
