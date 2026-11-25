# services/legal-pages/default.nix
# Deux pages statiques (politique de confidentialite + CGU) servies en
# local sur 127.0.0.1:8077, exposees publiquement SANS SSO via la
# ressource Pangolin `legal-pages` (legal.marcpartensky.com).
# But: satisfaire l'enregistrement d'applications personnelles chez
# les agregateurs open-banking (Enable Banking exige privacy_url et
# terms_url publics pour une app PRODUCTION en mode restricted).
# Contenu verifie par marc avant publication: ces pages engagent son
# nom (responsable de traitement = Marc Partensky).
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
