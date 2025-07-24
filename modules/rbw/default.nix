{ pkgs, ...} : {
  programs.rbw = {
    enable = true;
    settings = {
      email = "marc@marcpartensky.com";
      lock_timeout = 300;
      pinentry = pkgs.pinentry-gnome3;
    };
  };
}
