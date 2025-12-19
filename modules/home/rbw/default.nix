{ pkgs, ...} :
let
  vault_url = "https://vault.marcpartensky.com";
in
{
  programs.rbw = {
    enable = true;
    settings = {
      email = "marc@marcpartensky.com";
      lock_timeout = 300;
      base_url = "${vault_url}";
      identity_url = "${vault_url}";
      # pinentry = pkgs.pinentry-gnome3;
    };
  };
}
