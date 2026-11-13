# services/tuptime : historique LOCAL de disponibilite de la machine.
#
# Chaque machine tient son propre journal : demarrages, uptime cumule, DOWNTIME
# cumule (le trou entre l'arret et le boot suivant), ratio de disponibilite, et
# detection des arrets sales. Une base SQLite dans /var/lib/tuptime, un oneshot
# au demarrage et un timer toutes les 5 min : le cout CPU est nul (quelques
# millisecondes par tick).
#
# C'est la couche qu'un moniteur central ne peut PAS fournir : elle survit a une
# coupure reseau et a une panne du VPS, et elle donne des chiffres par machine
# plutot qu'une impression (« est ce que tower tombe souvent ? »).
#
# Lecture : `tuptime` (resume), `tuptime -t 10` (dix derniers evts).
{ ... }:
{
  services.tuptime = {
    enable = true;

    # Le timer est ce qui compte : sans point regulier pendant que la machine
    # tourne, un arret sale est compte comme si elle avait tourne jusqu'au boot
    # suivant, et le downtime disparait du total.
    timer.enable = true;
  };
}
