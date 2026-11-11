#!/usr/bin/env bash
# scripts/photos-pull.sh
# Rapatrie les photos du telephone de marc vers tower, source par source.
#
# DEUX TRANSPORTS, un seul point d'entree :
#   - ssh : `ssh phone` + tar en flux. Aucun geste materiel, MAIS l'appli
#     Nix-on-Droid doit avoir l'autorisation de stockage : sans elle, Android
#     refuse la lecture de /storage/emulated/0 meme en ssh (permission d'OS,
#     pas un identifiant qu'on pourrait obtenir depuis tower).
#   - adb : `adb exec-out tar` (fallback `adb pull -a`). Marche sans cette
#     permission, mais exige le cable USB ou le debogage sans fil.
#
# POURQUOI le transfert part de tower dans les deux cas : le shell du tel ne
# lit pas /storage/emulated/0 (scoped storage) et n'heberge aucun serveur de
# fichiers. Rien ne peut donc etre pousse DEPUIS le tel vers tower.
#
# Reprise : un marqueur par sous-dossier deja rapatrie ($ROOT/.pulled/<src>-<slug>).
# Relancer la meme commande reprend ce qui manque sans refaire le reste, ce qui
# compte derriere un relais (ordre de 0,2 Mo/s).
#
# Usage:
#   scripts/photos-pull.sh                    # tout, transport automatique
#   scripts/photos-pull.sh camera             # une source
#   scripts/photos-pull.sh --dry-run          # ce qui serait rapatrie
#   scripts/photos-pull.sh --force whatsapp   # ignore les marqueurs
#   scripts/photos-pull.sh --via adb          # force un transport (adb|ssh)
set -euo pipefail

# Arbre du groupe `photos` (marc + hermes, 2770 setgid) : une session hermes
# ouverte avant la creation du groupe l'ignore -> re-execution via sg.
if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx photos; then
  exec sg photos -c "$(printf '%q ' "$0" "$@")"
fi

ROOT=${PHOTOS_ROOT:-/home/marc/media/photos}
MARKERS="$ROOT/.pulled"
SSH_HOST=${SSH_HOST:-phone}
STORAGE=/storage/emulated/0
ADB=${ADB:-$(command -v adb 2>/dev/null || ls -d /nix/store/*android-tools-*/bin/adb 2>/dev/null | tail -1 || true)}

declare -A REMOTE_PATHS=(
  [camera]="$STORAGE/DCIM/Camera $STORAGE/DCIM/Screenshots $STORAGE/Pictures"
  [whatsapp]="$STORAGE/Android/media/com.whatsapp/WhatsApp/Media"
  [messenger]="$STORAGE/Android/media/com.facebook.orca $STORAGE/Android/data/com.facebook.orca"
)

DRY_RUN=0
FORCE=0
VIA=auto
WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --via) VIA=${2:-auto}; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) WANTED+=("$1") ;;
  esac
  shift
done
[ ${#WANTED[@]} -eq 0 ] && WANTED=(camera whatsapp messenger)

# --- choix du transport -----------------------------------------------------
ssh_ok() { timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true >/dev/null 2>&1; }
ssh_can_read() { timeout 40 ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; ls $STORAGE" >/dev/null 2>&1; }
adb_serial() {
  [ -n "$ADB" ] && [ -x "$ADB" ] || return 1
  local s
  s=$("$ADB" devices 2>/dev/null | awk '$2 == "device" && $1 !~ /^emulator-/ {print $1; exit}')
  # awk sort 0 meme sans resultat : sans ce test, un adb sans appareil passait
  # pour un transport valide et le script parlait a un SERIAL vide.
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

SERIAL=""
TRANSPORT=none
case "$VIA" in
  ssh) ssh_ok && ssh_can_read && TRANSPORT=ssh || TRANSPORT=none ;;
  adb) SERIAL=$(adb_serial) && TRANSPORT=adb || TRANSPORT=none ;;
  auto)
    if ssh_ok && ssh_can_read; then
      TRANSPORT=ssh
    elif SERIAL=$(adb_serial); then
      TRANSPORT=adb
    fi
    ;;
  *) echo "transport inconnu : $VIA (adb, ssh ou auto)" >&2; exit 2 ;;
esac

if [ "$TRANSPORT" = none ]; then
  reach="injoignable"
  if ssh_ok; then
    reach="joignable en ssh, mais /storage/emulated/0 est refuse (autorisation de stockage absente)"
  fi
  cat >&2 <<EOF
Aucun transport utilisable pour rapatrier les photos.

  ssh $SSH_HOST : $reach
  adb : $( [ -n "${SERIAL:-}" ] && echo "appareil $SERIAL" || echo "aucun appareil en etat 'device'" )

Le geste qui debloque le plus (aucun cable, aucun toggle par boot) :
  telephone > Parametres > Applis > Nix-on-Droid > Autorisations >
  Fichiers et medias > « Autoriser la gestion de tous les fichiers ».
  Ensuite ce script bascule tout seul sur ssh, rien d'autre a faire.

Autre voie : cable USB sur tower, ou Debogage sans fil (port affiche).
EOF
  exit 1
fi

echo "transport : $TRANSPORT$( [ "$TRANSPORT" = adb ] && echo " (appareil $SERIAL)" || echo " (ssh $SSH_HOST)" )"

# --- acces distant ----------------------------------------------------------
# PATH /system/bin cote tel : toybox fournit tar, find, du, ls.
remote_tar() { # $1=parent  $2=nom
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" exec-out tar -C "$1" -cf - "$2" ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; tar -C '$1' -cf - '$2'" ;;
  esac
}
remote_ls() { # $1=dossier
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "ls -1 '$1'" ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; ls -1 '$1'" ;;
  esac
}
remote_du() { # $1=dossier
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "du -sh '$1' 2>/dev/null | cut -f1" ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; du -sh '$1' 2>/dev/null | cut -f1" ;;
  esac
}
remote_is_dir() {
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "[ -d '$1' ]" >/dev/null 2>&1 ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "test -d '$1'" >/dev/null 2>&1 ;;
  esac
}

command -v tar >/dev/null 2>&1 || { echo "tar manquant sur tower" >&2; exit 1; }
mkdir -p "$MARKERS"

pull_dir() { # $1=source  $2=dossier distant
  local source="$1" remote="$2" dest="$ROOT/$source" parent sub slug marker
  if ! remote_is_dir "$remote"; then
    echo "  $remote : absent ou illisible, ignore"
    return 0
  fi
  parent=$(dirname "$remote")
  local subs
  subs=$(remote_ls "$remote" 2>/dev/null | tr -d '\r' | grep -v '^\.\{1,2\}$' || true)
  [ -n "$subs" ] || echo "  $remote : vide"
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    slug=$(printf '%s' "$remote/$sub" | tr '/ ' '__')
    marker="$MARKERS/${source}-${slug}"
    if [ $FORCE -eq 0 ] && [ -f "$marker" ]; then
      echo "  $remote/$sub : deja rapatrie"
      continue
    fi
    if [ $DRY_RUN -eq 1 ]; then
      echo "  $remote/$sub : $(remote_du "$remote/$sub" | tr -d '\r')"
      continue
    fi
    mkdir -p "$dest"
    echo "  -> $remote/$sub"
    if remote_tar "$parent" "$sub" | tar -C "$dest" -xf -; then
      touch "$marker"
    else
      echo "     interrompu : relancer la meme commande pour reprendre" >&2
      return 1
    fi
  done <<<"$subs"
}

rc=0
for source in "${WANTED[@]}"; do
  echo "=== $source ==="
  [ -n "${REMOTE_PATHS[$source]:-}" ] || { echo "  source inconnue : $source" >&2; rc=1; continue; }
  for remote in ${REMOTE_PATHS[$source]}; do
    pull_dir "$source" "$remote" || rc=1
  done
  if [ $DRY_RUN -eq 0 ] && [ -d "$ROOT/$source" ]; then
    echo "  local : $(find "$ROOT/$source" -type f | wc -l) fichiers, $(du -sh "$ROOT/$source" | cut -f1)"
  fi
done

if [ $DRY_RUN -eq 0 ]; then
  cat <<'EOF'

Rapatriement termine. Suite :
  scripts/photos-mirror.sh     # pousse vers Garage maintenant (sinon timer horaire)
  scripts/photos-status.sh     # compare l'arbre local et les buckets
EOF
fi
exit $rc
