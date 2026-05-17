{ pkgs, ... }:

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    # neovim providers
    pynvim
    python-lsp-server

    # quant / data science
    numpy
    pandas
    scipy
    matplotlib

    # tooling
    ipython
    rich
    marimo
  ]);
in
{
  home.packages = [ pythonEnv ];
}
