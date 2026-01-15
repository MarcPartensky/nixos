{ ... }: {
  services.batsignal = {
    enable = true;
    extraArgs = [ "-p" "-m" "1" "-a" "ADP0" ]; # active les notifications lors du branchement et debranchement
  };
}
