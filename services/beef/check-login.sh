#!/usr/bin/env bash
# Verifie que la console accepte vraiment les identifiants de la config.
#
# Pourquoi cette unite existe : le seul symptome d'un mot de passe mal pose est
# un « impossible de se connecter » cote navigateur, alors que le service, lui,
# tourne. Ici on rejoue le login depuis un process qui a le droit de lire le
# secret (User=beef) et on journalise le verdict de BeEF. Le mot de passe n'est
# jamais ecrit dans le journal : seule la reponse de BeEF l'est.
#
# ATTENTION aux noms de champs : le handler lit `username-cfrm` et
# `password-cfrm` (Ext.form.FormPanel soumet en x-www-form-urlencoded). Un POST
# JSON avec `username`/`password` rend `{"success":false}` meme avec le bon mot
# de passe, parce que les deux champs lus sont vides.
set -euo pipefail

: "${BEEF_CONSOLE_URL:?BEEF_CONSOLE_URL manquant}"
: "${BEEF_PASSWORD_FILE:?BEEF_PASSWORD_FILE manquant}"

password=$(cat "$BEEF_PASSWORD_FILE")
if [ -z "$password" ]; then
  echo "beef-selfcheck: mot de passe sops VIDE" >&2
  exit 1
fi

# Attendre que BeEF reponde (le chargement prend quelques dizaines de secondes).
ready=no
for _ in $(seq 1 40); do
  if curl -s -o /dev/null "${BEEF_CONSOLE_URL}/hook.js"; then
    ready=yes
    break
  fi
  sleep 3
done
if [ "$ready" != yes ]; then
  echo "beef-selfcheck: BeEF ne repond pas sur ${BEEF_CONSOLE_URL}" >&2
  exit 1
fi

# Meme requete que le formulaire de la console, champ pour champ.
answer=$(curl -s -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "username-cfrm=${BEEF_USER}" \
  --data-urlencode "password-cfrm=${password}" \
  "${BEEF_CONSOLE_URL}/ui/authentication/login")

case "$answer" in
  *'"success":true'*)
    echo "beef-selfcheck: login console OK (mot de passe de ${#password} caracteres accepte)"
    ;;
  *)
    echo "beef-selfcheck: login console REFUSE par BeEF -> $answer" >&2
    exit 1
    ;;
esac
