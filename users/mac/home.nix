{ pkgs, inputs, config, ... }: {

  imports = [
    ../../modules/home/claude-commit
  ];

  home.username = "marc";
  home.homeDirectory = pkgs.lib.mkForce (if pkgs.stdenv.isDarwin then "/Users/marc" else "/home/marc");
  home.stateVersion = "25.11";
  home.packages = with pkgs; [
    gemini-cli
    geminicommit
  ];

  programs.home-manager.enable = true;

  programs.git = {
    enable = true;
    settings.user.name = "Marc Partensky";
    settings.user.email = "marc.partensky@gmail.com";
  };
  
  programs.zsh.enable = true;

}
