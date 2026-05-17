{
  inputs,
  pkgs,
  ...
}: {
  home.packages = [inputs.backtest.packages.${pkgs.system}.default];

  systemd.user.services.backtest = {
    Unit.Description = "Backtest Streamlit dashboard";
    Unit.After = ["network.target"];
    Service = {
      ExecStart = "${inputs.backtest.packages.${pkgs.system}.default}/bin/backtest --server.port 8501";
      WorkingDirectory = "${inputs.backtest.packages.${pkgs.system}.default}/lib";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install.WantedBy = ["default.target"];
  };
}
