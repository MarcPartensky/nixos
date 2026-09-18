{inputs, ...}: {
  imports = [
    inputs.nixvim.homeModules.default
    ../../modules/home/git
    ../../modules/home/zsh
    ../../modules/home/ssh
    ../../modules/home/neovim
    ../../modules/home/starship
  ];

  home = {
    username = "marc";
    homeDirectory = "/home/marc";
    stateVersion = "25.11";
    sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };
  };

  programs.home-manager.enable = true;
}
