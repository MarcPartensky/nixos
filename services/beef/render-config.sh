#!/usr/bin/env bash
# Generates /var/lib/beef/config.yaml from the pinned upstream config.yaml.
#
# Two reasons to do it at startup rather than at build time:
#   - the Cloudflare quick tunnel name is random and changes on each
#     startup, and beef.http.public.host must carry EXACTLY this name (otherwise
#     the generated hook.js points to 127.0.0.1 and each browser hooks
#     itself: empty console, no error);
#   - the console password comes from a sops secret, never from the store.
#
# The upstream file is substituted line by line: it is safe because the
# source is pinned by hash, so these strings cannot drift. A
# verification on the produced artifact closes the residual risk.
set -euo pipefail

: "${BEEF_STATE_DIR:?BEEF_STATE_DIR missing}"
: "${BEEF_SRC_CONFIG:?BEEF_SRC_CONFIG missing}"
: "${BEEF_PASSWORD_FILE:?BEEF_PASSWORD_FILE missing}"
: "${BEEF_PORT:?BEEF_PORT missing}"

log="$BEEF_STATE_DIR/cloudflared.log"
host=""

# The tunnel takes a few seconds to announce its name. We read the LAST
# occurrence: cloudflared appends to the log, a restart leaves the old URL.
for _ in $(seq 1 90); do
  host=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | tail -1 || true)
  if [ -n "$host" ]; then
    break
  fi
  sleep 2
done

if [ -z "$host" ]; then
  echo "beef: no tunnel URL in $log (cloudflared started?)" >&2
  exit 1
fi

hostname="${host#https://}"
password=$(cat "$BEEF_PASSWORD_FILE")
out="$BEEF_STATE_DIR/config.yaml"

cp "$BEEF_SRC_CONFIG" "$out"

sed -i \
  -e 's|^        host: "0.0.0.0"$|        host: "127.0.0.1"|' \
  -e "s|^        port: \"3000\"\$|        port: \"$BEEF_PORT\"|" \
  -e 's|^        allow_reverse_proxy: false$|        allow_reverse_proxy: true|' \
  -e "s|^        passwd: \"beef\"\$|        passwd: \"$password\"|" \
  -e "s|^        file: \"beef.db\"\$|        file: \"$BEEF_STATE_DIR/beef.db\"|" \
  "$out"

# Public block: the four lines commented upstream become the real
# declaration (public host, port 443, https).
sed -i \
  -e "s|^        #public:\$|        public:\\n            host: \"$hostname\"\\n            port: \"443\"\\n            https: true|" \
  -e '/^        #    host: "beef.local"/d' \
  -e '/^        #    port: "443"/d' \
  -e '/^        #    https: false/d' \
  "$out"

# Verification on the artifact, not on the intent.
grep -q "host: \"$hostname\"" "$out" || {
  echo "beef: public.host not set in $out" >&2
  exit 1
}
grep -q "port: \"$BEEF_PORT\"" "$out" || {
  echo "beef: listening port not set in $out" >&2
  exit 1
}
grep -q 'allow_reverse_proxy: true' "$out" || {
  echo "beef: allow_reverse_proxy not set in $out" >&2
  exit 1
}
if grep -q 'passwd: "beef"' "$out"; then
  echo "beef: default password still present in $out" >&2
  exit 1
fi

chmod 600 "$out"
printf '%s\n' "$hostname" > "$BEEF_STATE_DIR/public-host"

# The password must be PRESENT and IDENTICAL to the one in the secret. Without this
# check, a secret read empty at render time produces "passwd: """, the
# service starts, and the console then refuses any credential without anything
# signaling it (checked on the bench: two renders four hours apart, only a
# check on the artifact distinguishes the two cases).
if [ -z "$password" ]; then
  echo "beef: sops password EMPTY ($BEEF_PASSWORD_FILE)" >&2
  exit 1
fi
if ! grep -qF "passwd: \"$password\"" "$out"; then
  echo "beef: the password in $out does not match the sops secret" >&2
  exit 1
fi

echo "beef: public lure on https://$hostname (local console on /ui/panel)"
echo "beef: password of ${#password} characters set in $out"
