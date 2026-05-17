{
  inputs,
  pkgs,
  ...
}: {
  home.packages = [inputs.portfolio-optimizer.packages.${pkgs.system}.default];

  systemd.user.services.portfolio-optimizer = {
    Unit.Description = "portfolio-optimizer Streamlit dashboard";
    Unit.After = ["network.target"];
    Service = {
      ExecStart = "${inputs.portfolio-optimizer.packages.${pkgs.system}.default}/bin/portfolio-optimizer --server.port 8502";
      WorkingDirectory = "${inputs.portfolio-optimizer.packages.${pkgs.system}.default}/lib";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install.WantedBy = ["default.target"];
  };
}
