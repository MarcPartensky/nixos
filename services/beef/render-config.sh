#!/usr/bin/env bash
# Genere /var/lib/beef/config.yaml a partir du config.yaml upstream epingle.
#
# Deux raisons de le faire au demarrage plutot qu'a la construction :
#   - le nom du tunnel rapide Cloudflare est aleatoire et change a chaque
#     demarrage, or beef.http.public.host doit porter EXACTEMENT ce nom (sinon
#     le hook.js genere pointe sur 127.0.0.1 et chaque navigateur se hooke
#     lui-meme : console vide, aucune erreur) ;
#   - le mot de passe de la console vient d'un secret sops, jamais du store.
#
# Le fichier upstream est substitue ligne a ligne : c'est sur parce que la
# source est epinglee par hash, donc ces chaines ne peuvent pas deriver. Une
# verification sur l'artefact produit referme le risque residuel.
set -euo pipefail

: "${BEEF_STATE_DIR:?BEEF_STATE_DIR manquant}"
: "${BEEF_SRC_CONFIG:?BEEF_SRC_CONFIG manquant}"
: "${BEEF_PASSWORD_FILE:?BEEF_PASSWORD_FILE manquant}"
: "${BEEF_PORT:?BEEF_PORT manquant}"

log="$BEEF_STATE_DIR/cloudflared.log"
host=""

# Le tunnel met quelques secondes a annoncer son nom. On lit la DERNIERE
# occurrence : cloudflared ajoute au log, un redemarrage laisse l'ancienne URL.
for _ in $(seq 1 90); do
  host=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | tail -1 || true)
  if [ -n "$host" ]; then
    break
  fi
  sleep 2
done

if [ -z "$host" ]; then
  echo "beef: aucune URL de tunnel dans $log (cloudflared demarre ?)" >&2
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

# Bloc public : les quatre lignes commentees en amont deviennent la vraie
# declaration (hote public, port 443, https).
sed -i \
  -e "s|^        #public:\$|        public:\\n            host: \"$hostname\"\\n            port: \"443\"\\n            https: true|" \
  -e '/^        #    host: "beef.local"/d' \
  -e '/^        #    port: "443"/d' \
  -e '/^        #    https: false/d' \
  "$out"

# Verification sur l'artefact, pas sur l'intention.
grep -q "host: \"$hostname\"" "$out" || {
  echo "beef: public.host non pose dans $out" >&2
  exit 1
}
grep -q "port: \"$BEEF_PORT\"" "$out" || {
  echo "beef: port d'ecoute non pose dans $out" >&2
  exit 1
}
grep -q 'allow_reverse_proxy: true' "$out" || {
  echo "beef: allow_reverse_proxy non pose dans $out" >&2
  exit 1
}
if grep -q 'passwd: "beef"' "$out"; then
  echo "beef: mot de passe par defaut encore present dans $out" >&2
  exit 1
fi

chmod 600 "$out"
printf '%s\n' "$hostname" > "$BEEF_STATE_DIR/public-host"

# Le mot de passe doit etre PRESENT et IDENTIQUE a celui du secret. Sans ce
# controle, un secret lu vide a l'instant du rendu produit « passwd: "" », le
# service demarre, et la console refuse ensuite tout identifiant sans que rien
# ne le signale (verifie au banc : deux rendus a quatre heures d'ecart, seul un
# controle sur l'artefact distingue les deux cas).
if [ -z "$password" ]; then
  echo "beef: mot de passe sops VIDE ($BEEF_PASSWORD_FILE)" >&2
  exit 1
fi
if ! grep -qF "passwd: \"$password\"" "$out"; then
  echo "beef: le mot de passe de $out ne correspond pas au secret sops" >&2
  exit 1
fi

echo "beef: leurre public sur https://$hostname (console locale sur /ui/panel)"
echo "beef: mot de passe de ${#password} caracteres pose dans $out"
