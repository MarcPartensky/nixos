#!/bin/sh
# nod-bootstrap.sh : provisionne (ou repare) un appareil Android Nix-on-Droid
# pour le pilotage a distance et longue duree par l'agent de marc.
#
# Sur l'appareil, dans le terminal de l'app Nix-on-Droid (com.termux.nix) :
#   curl -fsSL <lien-court> | sh                 # installe / met a jour / repare
#   curl -fsSL <lien-court> | sh -s status       # etat seulement, ne touche a rien
#
# Fonctionne aussi deja installe, pour un switch de maintenance :
#   /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/nod-bootstrap
#
# Variables (toutes optionnelles) :
#   NOD_FLAKE     flake a deployer           (defaut github:MarcPartensky/nixos)
#   NOD_DEVICE    attribut de configuration  (defaut : `default`)
#   NOD_RELAY_KEY cle ed25519 de relais en base64, ecrite dans ~/.ssh/relay_ed25519
#                 (sans elle, l'appareil reste joignable en ssh sur le LAN, :8023)
#   NOD_NO_SWITCH 1 = ne pas relancer le switch (verification seule)
#
# Aucun secret n'est contenu dans ce script : il n'est la que pour rendre
# l'appareil declaratif, reproductible et reparables en une commande.

set -u

MODE=install
case "${1:-}" in
  status|--status|-s) MODE=status ;;
  install|--install|"") MODE=install ;;
  *) printf 'usage: nod-bootstrap [status]\n' >&2; exit 2 ;;
esac

NOD_HOME="${HOME:-/data/data/com.termux.nix/files/home}"
NOD_FLAKE="${NOD_FLAKE:-github:MarcPartensky/nixos}"
NOD_DEVICE="${NOD_DEVICE:-}"
NOD_TTL="${NOD_TTL:-0}"
GEN_BIN=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin

say()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; printf 'NOD-BOOTSTRAP-FAILED\n'; exit 1; }
ok()   { printf ' ok  %s\n' "$*"; }

# Resout un binaire : generation courante, puis profil utilisateur, puis PATH.
# La generation courante est le chemin STABLE pose par nix-on-droid : il survit
# a un switch et resout toujours l'environnement actif.
find_bin() {
  name=$1
  for p in "$GEN_BIN/$name" "$NOD_HOME/.nix-profile/bin/$name"; do
    if [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  return 1
}

say "nod-bootstrap, mode=$MODE, $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'date inconnue')"
say "home=$NOD_HOME"
case "$NOD_HOME" in
  */com.termux.nix/*|*/termux.nix/*) ok "environnement Nix-on-Droid reconnu" ;;
  *) warn "HOME inattendu : ce script vise l'app Nix-on-Droid (com.termux.nix). On continue quand meme." ;;
esac

# --- etat seul ---------------------------------------------------------------
report_state() {
  s=0
  for b in sshd phone-up phone-status phone-watchdog zsh git; do
    if p=$(find_bin "$b"); then ok "$b -> $p"; else warn "$b ABSENT"; s=1; fi
  done
  if [ -x "$GEN_BIN/phone-status" ]; then
    say "phone-status :"
    "$GEN_BIN/phone-status" || warn "phone-status a echoue"
  fi
  if p=$(find_bin curl); then ok "curl -> $p"; else warn "curl ABSENT (le lien court ne pourra pas etre relance sur cet appareil)"; fi
  return $s
}

if [ "$MODE" = status ]; then
  report_state || warn "etat incomplet"
  printf 'NOD-BOOTSTRAP-STATUS-DONE\n'
  exit 0
fi

# --- cle de relais (optionnelle) --------------------------------------------
if [ -n "${NOD_RELAY_KEY:-}" ]; then
  say "ecriture de la cle de relais dans ~/.ssh/relay_ed25519"
  umask 077
  mkdir -p "$NOD_HOME/.ssh"
  if printf '%s' "$NOD_RELAY_KEY" | base64 -d > "$NOD_HOME/.ssh/relay_ed25519" 2>/dev/null; then
    chmod 600 "$NOD_HOME/.ssh/relay_ed25519"
    ok "cle de relais posee (tunnel sortant vers le VPS actif au prochain phone-up)"
  else
    warn "base64 illisible : cle NON posee"
  fi
  unset NOD_RELAY_KEY
fi

# --- switch declaratif ------------------------------------------------------
NOD_BIN_CONF=$(find_bin nix-on-droid) \
  || die "binaire nix-on-droid introuvable : installer d'abord l'app Nix-on-Droid (F-Droid, com.termux.nix) et repondre y a la question sur les flakes."

if [ "${NOD_NO_SWITCH:-0}" = 1 ]; then
  say "NOD_NO_SWITCH=1 : switch saute"
else
  TARGET="$NOD_FLAKE"
  [ -n "$NOD_DEVICE" ] && TARGET="$NOD_FLAKE#$NOD_DEVICE"
  say "switch depuis $TARGET (tarball-ttl $NOD_TTL)"
  say "premier build : plusieurs minutes, l'ecran peut sembler fige. Ne pas fermer l'app."
  # Le fetcher de nix met en cache les refs non epinglees (~1 h) : tarball-ttl 0
  # force la resolution fraiche, indispensable juste apres un push de la config.
  # Le switch ne tue ni sshd ni les boucles deja lancees : la session survit.
  if [ "$NOD_TTL" = 0 ]; then
    "$NOD_BIN_CONF" switch --flake "$TARGET" --option tarball-ttl 0
  else
    "$NOD_BIN_CONF" switch --flake "$TARGET" --option tarball-ttl "$NOD_TTL"
  fi || die "le switch a echoue : lire les 20 dernieres lignes ci-dessus (souvent un nom de fichier ou une variable mal nommee dans un module)."
  ok "generation active"
fi

# --- demarrage des services -------------------------------------------------
if p=$(find_bin phone-up); then
  say "phone-up (sshd, tunnels, watchdog, wake-lock)"
  "$p" || warn "phone-up a renvoye un code non nul (voir ~/sshd/up.log)"
else
  warn "phone-up absent du profil : le switch n'a pas deploye le module d'acces (verifier profiles/nix-on-droid)."
fi
sleep 3

# --- verification ------------------------------------------------------------
say "verification"
FAIL=0
for b in sshd phone-up phone-status zsh git; do
  if p=$(find_bin "$b"); then ok "$b"; else warn "$b ABSENT"; FAIL=1; fi
done
if p=$(find_bin curl); then ok "curl (le lien court est relancable sur cet appareil)"; else warn "curl absent : l'appareil ne pourra pas se rebootstrap seul (ajouter curl a environment.packages)"; fi

# sshd ecoute-t-il ? (uid app : pas de ss/netlink, mais /dev/tcp suffit)
if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8023' 2>/dev/null; then
  ok "sshd joignable sur 127.0.0.1:8023"
else
  warn "sshd ne repond pas sur 127.0.0.1:8023 (relancer phone-up ; sinon lire ~/sshd/up.log)"
  FAIL=1
fi

# IP LAN : sous uid app, la lecture netlink est parfois refusee, on tolere.
if p=$(find_bin ip); then
  LAN=$("$p" -4 -o addr show wlan0 2>/dev/null | grep -o '[0-9][0-9.]*/[0-9]*' | head -1 | cut -d/ -f1)
  [ -n "$LAN" ] && ok "wlan0 = $LAN  (ssh -p 8023 nix-on-droid@$LAN)"
fi

if [ -x "$GEN_BIN/phone-status" ]; then
  say "phone-status :"
  "$GEN_BIN/phone-status" || warn "phone-status a echoue"
fi

cat <<'CHECKLIST'

--- les 4 reglages Android qui tiennent l'appareil en vie (une fois) -------------
 1. Nix-on-Droid : demarrage automatique ON (Parametres > Applis > Nix-on-Droid)
 2. batterie : AUCUNE restriction (le tueur d'apps HyperOS sinon gele l'app)
 3. permission "Afficher les fenetres pop-up" (requise par le wake-lock)
 4. verrouiller l'app dans les recents (cadenas)
 controle : dans une session, `termux-wake-lock; echo $?` doit afficher 0

--- ensuite ---------------------------------------------------------------
 relancer la meme commande courte = mise a jour + reparation (idempotent)
 etat :  /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/nod-bootstrap status
CHECKLIST

if [ "$FAIL" = 0 ]; then
  printf 'NOD-BOOTSTRAP-OK\n'
else
  printf 'NOD-BOOTSTRAP-OK-AVEC-RESERVES\n'
fi
exit 0
