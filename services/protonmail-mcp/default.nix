# services/protonmail-mcp/default.nix
# Proton Mail Bridge headless (service système) + serveur MCP
# proton-mail-bridge-client, câblés via le flake local ../../protonmail-mcp
# (nixosModules.default = inputs.protonmail-mcp.nixosModules.default, importé
# directement dans flake.nix pour tower).
#
# Secret sops : secrets/protonmail.yml, fichier SÉPARÉ de tower.yml — hermes
# n'a ni le binaire sops ni la clé age privée de tower (lecture seule pour
# root), donc pas moyen de rééditer tower.yml en place. Un fichier neuf ne
# demande que les clés PUBLIQUES déjà présentes dans .sops.yaml -> chiffrable
# par hermes via `nix run nixpkgs#sops -- --encrypt --in-place`.
# Contient pour l'instant un mot de passe PLACEHOLDER (Bridge non logué) :
# le service démarre mais le MCP n'authentifie pas encore.
#
# PREMIER LOGIN (une fois, humain — nécessite le vrai mot de passe Proton de
# marc.partensky@proton.me, potentiellement 2FA) :
#   sudo protonmail-bridge-login
#   Dans le CLI Bridge : login, puis info (copier le mot de passe Bridge généré),
#   puis exit.
# Ensuite : remplacer le placeholder dans secrets/protonmail.yml par ce mot de
# passe (re-chiffrement complet du fichier, toujours sans clé privée), puis
# décommenter la ligne services.hermes-agent.mcpServers.protonmail ci-dessous
# et relancer `just nixos`.
{config, ...}: {
  sops.secrets."protonmail/bridge-password" = {
    sopsFile = ../../secrets/protonmail.yml;
    key = "bridge_password";
    owner = "hermes";
  };

  services.protonmail-mcp = {
    # DÉSACTIVÉ : Proton Mail Bridge exige un plan payant. Le login Bridge a été
    # tenté le 24/09/2026 et refusé par l'API Proton :
    #   422 POST https://mail-api.proton.me/auth/v4: Please upgrade to a paid plan
    #   to use this client (Code=10004)
    # L'auto-forwarding est payant lui aussi (même via filtre custom), donc aucune
    # voie gratuite : la lecture des mails passe par le webmail piloté au
    # navigateur (services/firefox-mcp + firefox-mcp-login).
    # Tout est conservé (flake ../../protonmail-mcp, secret, user système) : il
    # suffit de repasser enable = true si marc prend Mail Plus un jour.
    enable = false;
    username = "marc.partensky@proton.me";
    passwordFile = config.sops.secrets."protonmail/bridge-password".path;
  };

  # À décommenter seulement après le premier login Bridge (mot de passe réel
  # dans secrets/protonmail.yml, pas le placeholder) :
  # services.hermes-agent.mcpServers.protonmail = config.services.protonmail-mcp.mcpServer;
}
