{
  inputs,
  pkgs,
  ...
}: {
  home.packages = [inputs.option-pricer.packages.${pkgs.system}.default];
  systemd.user.services.option-pricer = {
    Unit.Description = "option-pricer Streamlit dashboard";
    Unit.After = ["network.target"];
    Service = {
      ExecStart = "${inputs.option-pricer.packages.${pkgs.system}.default}/bin/option-pricer --server.port 8501";
      WorkingDirectory = "${inputs.option-pricer.packages.${pkgs.system}.default}/lib/option-pricer";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install.WantedBy = ["default.target"];
  };
}
