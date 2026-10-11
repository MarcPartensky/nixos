# services/hinge-auto/default.nix
# Auto-like Hinge web (app.hinge.co) via Playwright + Chromium, sur le patron
# exact de services/amazon-mcp : profil chromium persistant dans
# /var/lib/hermes/hinge-auto/user-data, ACL marc pour le login manuel visible.
#
# Deux binaires installes dans le profil systeme :
#   hinge-auto-login     chromium VISIBLE, a lancer depuis une session graphique
#                        de marc (wayvnc/kasm) : telephone + SMS, Entree = sauve.
#                        Un seul login tenace jusqu'a expiration de session.
#   hinge-auto-like      boucle de likes headless sur Discover (HINGE_HEADLESS=0
#                        pour voir ce que fait le navigateur). Garde-fous :
#                        HINGE_MAX_LIKES (defaut 40) + detection de fin de flux.
#   hinge-auto-calibrate dump des boutons pour affiner les selecteurs.
#
# NB : le profil persistant ne supporte PAS deux instances chromium en meme
# temps (lock) : ne pas lancer login pendant qu'un like tourne.
#
# Limite gratuite Hinge : ~8 likes/jour (Hinge+/X = illimite). Le script s'arrete
# sur le marqueur de fin, pas sur un compte fixe.
{ pkgs, ... }:
let
  python = pkgs.python312;
  py = python.pkgs;

  script = pkgs.writeText "hinge_auto.py" (builtins.readFile ./hinge_auto.py);

  playwrightPython = python.withPackages (ps: [ ps.playwright ]);
in {
  # Helpers dispo pour marc (login visible) et pour un run serveur (like).
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hinge-auto-login";
      runtimeInputs = [ playwrightPython ];
      text = ''
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        exec python3 ${script} login
      '';
    })
    (pkgs.writeShellApplication {
      name = "hinge-auto-like";
      runtimeInputs = [ playwrightPython ];
      text = ''
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        export HINGE_HEADLESS="''${HINGE_HEADLESS:-1}"
        exec python3 ${script} like
      '';
    })
    (pkgs.writeShellApplication {
      name = "hinge-auto-calibrate";
      runtimeInputs = [ playwrightPython ];
      text = ''
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        exec python3 ${script} calibrate
      '';
    })
  ];

  # Profil persistant partage hermes <-> marc (login). Pattern amazon-mcp :
  # /var/lib/hermes en 2770 hermes:hermes, marc a besoin du --x de traversee.
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "d /var/lib/hermes/hinge-auto 0750 hermes hermes - -"
    "a /var/lib/hermes/hinge-auto - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
  ];
}