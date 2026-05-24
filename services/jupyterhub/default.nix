{
  pkgs,
  config,
  lib,
  ...
}: let
  pythonPackages = ps:
    with ps; [
      ipykernel
      numpy
      pandas
      scipy
      matplotlib
      scikit-learn
      yfinance
      statsmodels
    ];

  pythonEnv = pkgs.python3.withPackages pythonPackages;

  jupyterlabEnv = pkgs.python3.withPackages (ps:
    with ps;
      [
        jupyterlab
        jupyterhub
      ]
      ++ pythonPackages ps);
in {
  sops.secrets."jupyterhub/secret_token" = {
    key = "jupyterhub_secret_token";
  };

  services.jupyterhub = {
    enable = true;
    host = "0.0.0.0";
    port = 8082;
    authentication = "pam";
    spawner = "simple";

    inherit jupyterlabEnv;

    jupyterhubEnv = pkgs.python3.withPackages (ps:
      with ps; [
        jupyterhub
      ]);

    kernels.python3 = {
      displayName = "Python 3 (Data Science)";
      argv = [
        "${pythonEnv}/bin/python"
        "-m"
        "ipykernel_launcher"
        "-f"
        "{connection_file}"
      ];
      language = "python";
      logo32 = "${pythonEnv}/${pythonEnv.sitePackages}/ipykernel/resources/logo-32x32.png";
      logo64 = "${pythonEnv}/${pythonEnv.sitePackages}/ipykernel/resources/logo-64x64.png";
    };

    extraConfig = ''
      with open("${config.sops.secrets."jupyterhub/secret_token".path}") as f:
          c.JupyterHub.proxy_auth_token = f.read().strip()

      c.Authenticator.admin_users = {"marc"}
      c.Authenticator.allowed_users = {"marc"}
      c.PAMAuthenticator.open_sessions = False
      c.Spawner.notebook_dir = "~"
      c.Spawner.cmd = ["${jupyterlabEnv}/bin/jupyterhub-singleuser"]
      c.Spawner.args = ["--allow-root"]
    '';
  };
}
