# atop : enregistreur d'activité PAR PROCESS, rejouable après coup.
#
# Répond à « qu'est-ce qui a piqué le CPU à 13:42 ? » sans avoir eu un htop
# ouvert au bon moment. atop échantillonne /proc (CPU, mémoire, I/O, réseau par
# process) vers un fichier binaire journalier rejouable avec `atop -r`, et
# `atop-peaks` (ci-dessous, ajouté au PATH) sort le classement des pics sans
# passer par la TUI.
#
# Pourquoi atop et pas sar/netdata : `sar` échantillonne toutes les 10 min par
# défaut, trop grossier pour un burst de quelques secondes ; netdata est un
# démon web permanent bien plus lourd. atop est un seul process, ~8 % d'un cœur
# au pas de 10 s (scan de /proc pour ~4500 tâches, mesuré sur tower).
#
# atopacctd active l'accounting noyau : un process né et mort ENTRE deux
# échantillons (build, spawn de MCP, commande shell) reste visible dans
# l'échantillon suivant avec son CPU. C'est ce qui rend les pics de
# sous-processus visibles même à pas grossier.
#
# Coût disque mesuré : ~1,4 Go par jour (échantillon de ~170 Ko avec `-a`).
# On garde 3 jours ; remonter `generations` si une enquête longue se prépare.
{
  pkgs,
  ...
}:
let
  logInterval = 10; # secondes entre deux échantillons
  generations = 3; # fichiers journaliers conservés
in
{
  programs.atop = {
    enable = true;
    atopacctService.enable = true; # process éphémères comptés
    atopRotateTimer.enable = true; # un fichier par jour
  };

  # L'unité nixpkgs lance `atop -w .../atop_$(date +%Y%m%d) $LOGINTERVAL` avec
  # LOGINTERVAL=600 par défaut. Un drop-in NixOS surcharge ces variables
  # (dernière affectation gagnante en systemd).
  systemd.services.atop = {
    environment = {
      LOGINTERVAL = toString logInterval;
      LOGGENERATIONS = toString generations;
      LOGOPTS = "-a"; # CPU + mémoire + disque + réseau par process
    };
    # Télémétrie de fond : cède le pas à l'interactif sous contention.
    serviceConfig = {
      Slice = "background.slice";
      CPUWeight = 20;
      IOWeight = 20;
      Nice = 10;
    };
  };

  # Pas de netatop (module noyau hors arbre, taint du kernel) : le CPU et la
  # mémoire par process suffisent pour les pics qui nous concernent.

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "atop-peaks" ''
      exec ${pkgs.python3}/bin/python3 ${./atop-peaks.py} \
        --atop ${pkgs.atop}/bin/atop "$@"
    '')
  ];
}
