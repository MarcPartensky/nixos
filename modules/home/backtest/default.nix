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
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = "STREAMLIT_BROWSER_GATHER_USAGE_STATS=false";
    };
    Install.WantedBy = ["default.target"];
  };
}
