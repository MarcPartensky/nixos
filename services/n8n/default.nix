# n8n : automatisation de workflows (UI web), loopback 127.0.0.1:5678.
#
# Reprise de l'instance historique de tower : la ressource Pangolin
# `n8n.marcpartensky.com` (SSO actif, healthcheck par défaut `/healthz`) cible
# déjà 127.0.0.1:5678 ; il ne manquait que le service. Les données existantes
# vivent dans /var/lib/n8n (valeur par défaut de N8N_USER_FOLDER du module,
# réutilisée telle quelle) ; elles viennent d'un conteneur (uid inconnu), d'où
# le chown -R vers l'utilisateur dynamique du service au premier démarrage.
#
# Le firewall reste fermé (openFirewall défaut false) : accès via newt/Pangolin.
{ pkgs, ... }:
{
  services.n8n.enable = true;

  # Données héritées d'un conteneur : ré-approprier au service avant démarrage
  # (« + » = tourne en root avant le drop vers DynamicUser).
  systemd.services.n8n.serviceConfig.ExecStartPre = [
    "+${pkgs.coreutils}/bin/chown -R n8n:n8n /var/lib/n8n"
  ];
}
