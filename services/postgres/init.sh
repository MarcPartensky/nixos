#!/usr/bin/env nix-shell
#!nix-shell -i bash -p openssl

set -euo pipefail

CERT=/var/lib/postgresql/server.crt
KEY=/var/lib/postgresql/server.key

sudo openssl req -new -x509 -days 3650 \
  -nodes -text \
  -out "$CERT" \
  -keyout "$KEY" \
  -subj "/CN=postgres"

sudo chmod 600 "$KEY"
sudo chown postgres:postgres "$CERT" "$KEY"

echo "OK: $CERT et $KEY générés"
