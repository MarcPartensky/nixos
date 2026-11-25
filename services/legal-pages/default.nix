# services/legal-pages/default.nix
# Two static pages (privacy policy + ToS) served
# locally on 127.0.0.1:8077, exposed publicly WITHOUT SSO via the
# Pangolin resource `legal-pages` (legal.marcpartensky.com).
# Goal: satisfy the registration of personal applications with
# open-banking aggregators (Enable Banking requires public privacy_url and
# terms_url for a PRODUCTION app in restricted mode).
# Content verified by marc before publication: these pages commit his
# name (data controller = Marc Partensky).
{pkgs, ...}:
let
  site = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./site/privacy.html
      ./site/terms.html
    ];
  };
in
{
  systemd.services.legal-pages = {
    description = "Static legal pages for personal open-banking apps";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8077"
        + " --bind 127.0.0.1 --directory ${site}";
      Restart = "always";
      ProtectSystem = "strict";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
}
