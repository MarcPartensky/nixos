#!/bin/sh
# À lancer par marc, une seule fois : crée la paire de clés pqbox et scelle la
# clé privée avec un mot de passe que TOI seul tapes (l'agent ne le voit pas).
#
#   ./setup-key.sh            # crée backup.pub + ~/.config/pqbox/backup.key
#   ./setup-key.sh reseal     # change le mot de passe (même clé publique)
set -eu
cd "$(dirname "$0")"
mkdir -p "$HOME/.config/pqbox"
chmod 700 "$HOME/.config/pqbox"

if command -v pqbox >/dev/null 2>&1; then
  PQ=pqbox
elif [ -x /nix/var/nix/profiles/system/sw/bin/pqbox ]; then
  PQ=/nix/var/nix/profiles/system/sw/bin/pqbox
else
  echo "pqbox introuvable : lancer 'HOST=tower just nixos' d'abord" >&2
  exit 1
fi

case "${1:-keygen}" in
  keygen)
    exec $PQ keygen --pub "$PWD/backup.pub" --key "$HOME/.config/pqbox/backup.key"
    ;;
  reseal)
    exec $PQ reseal --key "$HOME/.config/pqbox/backup.key"
    ;;
  *)
    echo "usage: $0 [keygen|reseal]" >&2
    exit 2
    ;;
esac
