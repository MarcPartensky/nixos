{inputs, ...}: {
  home.stateVersion = "25.11";
  imports = [
    inputs.nixvim.homeModules.default
    ../../modules/home/neovim
    ../../modules/home/zsh
    ../../modules/home/git
    ../../modules/home/ssh
    ../../modules/home/gh
  ];
}
