{ pkgs, inputs, config, ... }: {

  imports = [
    # ../../modules/home/claude-commit
    ../../modules/home/ssh
    ../../modules/home/zsh
  ];

  home.username = "marc";
  home.homeDirectory = pkgs.lib.mkForce (if pkgs.stdenv.isDarwin then "/Users/marc" else "/home/marc");
  home.stateVersion = "25.11";
  home.packages = with pkgs; [
    gemini-cli
    geminicommit
    tree
    eza
    bat
  ];

  programs.home-manager ={
    enable = true;
    # backupFileExtension = "backup";
  # backupCommand',
   };

  programs.git = {
    enable = true;
    settings.user.name = "Marc Partensky";
    settings.user.email = "marc.partensky@gmail.com";
  };
  
  programs.zsh.enable = true;

}
