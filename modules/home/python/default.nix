{ pkgs, ... }:

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    # neovim providers
    pynvim
    python-lsp-server
    python-lsp-server
    ruff

    # quant / data science
    numpy
    pandas
    scipy
    matplotlib

    # tooling
    ipython
    ptpython
    rich
    marimo
  ]);
in
{
  home.packages = with pkgs; [
    pythonEnv
    basedpyright
  ];
}
