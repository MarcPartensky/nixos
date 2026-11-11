#!/bin/sh
# À lancer par marc, une seule fois : crée la paire de clés pqbox et scelle
# la clé privée avec un mot de passe que TOI seul tapes (l'agent ne le voit pas).
set -eu
cd "$(dirname "$0")"
mkdir -p "$HOME/.config/pqbox"
chmod 700 "$HOME/.config/pqbox"
exec ./pqbox keygen \
  --pub "$PWD/backup.pub" \
  --key "$HOME/.config/pqbox/backup.key"
