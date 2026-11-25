#!/bin/sh
# To be run by marc, only once: creates the pqbox key pair and seals the
# private key with a password that YOU alone type (the agent does not see it).
#
#   ./setup-key.sh            # creates backup.pub + ~/.config/pqbox/backup.key
#   ./setup-key.sh reseal     # changes the password (same public key)
set -eu
cd "$(dirname "$0")"
mkdir -p "$HOME/.config/pqbox"
chmod 700 "$HOME/.config/pqbox"

if command -v pqbox >/dev/null 2>&1; then
  PQ=pqbox
elif [ -x /nix/var/nix/profiles/system/sw/bin/pqbox ]; then
  PQ=/nix/var/nix/profiles/system/sw/bin/pqbox
else
  echo "pqbox not found: run 'HOST=tower just nixos' first" >&2
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
