# Point d'entree des services NixOS du PORTABLE.
#
# Le portable n'importe PLUS le monolithe ./services : celui-ci porte une
# soixantaine de modules propres a tower (Zitadel, Gitea, Immich, Matrix, banque,
# IBKR...) dont beaucoup declarent des secrets sops dont le portable n'est pas
# destinataire. Consequence mesuree le 20/11/2026 : le portable declarait 18
# fichiers sops (34 secrets) qu'il ne pouvait pas dechiffrer, dont 17 sans sa
# cle age. Le manifeste sops refuse alors de se construire et TOUT le build
# tombe, meme pour les secrets valides (cf. skill sops-nix-secrets, regle 1).
#
# Ce qu'il faut vraiment au portable :
#   - tailscale : il est deja enrole dans headscale, donc sans cle de pre-auth
#     (secrets/headscale.yml ne le liste pas) ;
#   - hermes : le gateway de secours, installe mais arrete au boot ;
#   - hermes-fallback : copie d'etat depuis tower + bascule automatique.
#
# Ce qu'il importe deja directement dans profiles/laptop : tts-mcp, llm-server,
# immich-ml, backup-pqbox, disko et hardware.
{...}: {
  imports = [
    ./tailscale
    ./hermes
    ./hermes-fallback
  ];

  # Node deja enregistre dans headscale : pas de cle de pre-authentification.
  meshTailscale.enablePreauthKey = false;

  # Pas de serveur MCP Gitea (secret secrets/gitea-mcp.yml, tower uniquement).
  services.hermes.enableGiteaMcp = false;
}