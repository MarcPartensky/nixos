{
  shellAliases = {
    ll = "ls -l";
    gs = "git status";
    ga = "git add -A";
    gm = "git commit -m";
    gn = "git add -A && git commit -m @";
    gt = "git add -A && git commit -m @ && git push";
    gp = "git push";
    gpl = "git pull";
    grsh = "git reset --hard HEAD";
    update = "sudo nixos-rebuild switch /etc/nixos#laptop";
    ipi = "http ipinfo.io";
    # ns = "nix-search-tv print |
    #   fzf --preview 'nix-search-tv preview {}' --scheme history";
  };
  shellAbbrs = {
    j = "just";
    v = "nvim";
    u = "update";
  };
}
