#!/usr/bin/env bash
# Checks that the console really accepts the credentials from the config.
#
# Why this unit exists: the only symptom of a badly set password is
# an "unable to log in" on the browser side, while the service itself
# runs. Here we replay the login from a process allowed to read the
# secret (User=beef) and log BeEF's verdict. The password is
# never written to the journal: only BeEF's answer is.
#
# WATCH OUT for field names: the handler reads `username-cfrm` and
# `password-cfrm` (Ext.form.FormPanel submits as x-www-form-urlencoded). A
# JSON POST with `username`/`password` returns `{"success":false}` even with the right
# password, because the two fields read are empty.
set -euo pipefail

: "${BEEF_CONSOLE_URL:?BEEF_CONSOLE_URL missing}"
: "${BEEF_PASSWORD_FILE:?BEEF_PASSWORD_FILE missing}"

password=$(cat "$BEEF_PASSWORD_FILE")
if [ -z "$password" ]; then
  echo "beef-selfcheck: sops password EMPTY" >&2
  exit 1
fi

# Wait for BeEF to answer (loading takes a few tens of seconds).
ready=no
for _ in $(seq 1 40); do
  if curl -s -o /dev/null "${BEEF_CONSOLE_URL}/hook.js"; then
    ready=yes
    break
  fi
  sleep 3
done
if [ "$ready" != yes ]; then
  echo "beef-selfcheck: BeEF does not answer on ${BEEF_CONSOLE_URL}" >&2
  exit 1
fi

# Same request as the console form, field for field.
answer=$(curl -s -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "username-cfrm=${BEEF_USER}" \
  --data-urlencode "password-cfrm=${password}" \
  "${BEEF_CONSOLE_URL}/ui/authentication/login")

case "$answer" in
  *'"success":true'*)
    echo "beef-selfcheck: console login OK (password of ${#password} characters accepted)"
    ;;
  *)
    echo "beef-selfcheck: console login REFUSED by BeEF -> $answer" >&2
    exit 1
    ;;
esac
