{
  j = "just";
  v = "nvim";
  u = "update";
  s = "sudo";
  l = "ls";
  c = "cd";
  m = "make";
  f = "find";
  d = "docker";
  r = "restart";
  g = "grep";

  ll = "ls -l";
  wh = "which";
  dc = "docker compose";
  ipi = "http ipinfo.io";

  sy = "systemctl";
  sys = "systemctl status";
  syr = "systemctl restart";
  syus = "systemctl --user status";
  syur = "systemctl --user restart";


  gs = "git status";
  ga = "git add -A";
  gc = "git commit -m";
  gn = "git add -A && git commit -m @";
  gt = "git add -A && git commit -m @ && git push";
  gd = "git diff";
  gp = "git push";
  gk = "git checkout";
  gpl = "git pull";
  grsh = "git reset --hard HEAD";
  grs = "git reset";

  sshp = "cat ~/.ssh/id_ed25519.pub";
  update = "just -f $HOME/git/nixos/Justfile";
  ch = "cd $(git rev-parse --show-toplevel)";

  password = "gpg --gen-random --armor 1 14";
}
