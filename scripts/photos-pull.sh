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
# Nombre d'entrees par flux tar (une photo par flux = un handshake ssh par
# photo). PHOTOS_BATCH=1 retrouve l'ancien comportement pour un diagnostic.
BATCH=${PHOTOS_BATCH:-200}
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
# ONLY=photos|videos|all : filtre par extension cote tel (utile pour DCIM/Camera
# ou deux tiers du volume sont des videos). `all` fait du sous-dossier par
# sous-dossier, `photos`/`videos` passent par une liste de fichiers
# (find | tar -T -) : toybox tar sait lire une liste sur stdin, verifie.
ONLY=${ONLY:-all}
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
remote_tar() { # $1=dossier distant  $2..=noms relatifs a ce dossier
  # Le tar part du dossier lui-meme. L'ancienne version prenait dirname($1),
  # donc pour /DCIM/Camera elle cherchait « Facebook » dans /DCIM : tout
  # echouait en « tar: Facebook: No such file or directory » (bug invisible
  # tant que l'autorisation de stockage manquait, le script sortait avant).
  #
  # `</dev/null` est OBLIGATOIRE : ssh lit son entree standard, qui est ici la
  # boucle `while read` de pull_dir. Sans cette redirection, le premier appel
  # avalait les lignes restantes de la liste et la passe s'arretait apres une
  # seule entree, sans message d'erreur.
  local dir="$1"
  shift
  local names=() quoted="" n
  for n in "$@"; do
    names+=("$n")
    quoted="$quoted'$n' "
  done
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" exec-out tar -C "$dir" -cf - "${names[@]}" </dev/null ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; tar -C '$dir' -cf - $quoted" </dev/null ;;
  esac
}
remote_ls() { # $1=dossier
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "ls -1 '$1'" </dev/null ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; ls -1 '$1'" </dev/null ;;
  esac
}
remote_du() { # $1=dossier
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "du -sh '$1' 2>/dev/null | cut -f1" </dev/null ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; du -sh '$1' 2>/dev/null | cut -f1" </dev/null ;;
  esac
}
remote_is_dir() {
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "[ -d '$1' ]" >/dev/null 2>&1 ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "test -d '$1'" >/dev/null 2>&1 ;;
  esac
}

# Extensions par mode. jpg/heic couvrent l'appareil photo de marc.
case "$ONLY" in
  photos) FIND_FILTER='\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.bmp" \)' ;;
  videos) FIND_FILTER='\( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.3gp" -o -iname "*.mkv" -o -iname "*.webm" -o -iname "*.avi" \)' ;;
  all) FIND_FILTER='' ;;
  *) echo "ONLY inconnu : $ONLY (photos, videos ou all)" >&2; exit 2 ;;
esac

# Flux d'un ARBRE ENTIER filtre par extension, en un seul tar (la liste de
# fichiers passe par stdin, toybox tar la lit avec -T -).
remote_tar_filtered() { # $1=dossier distant
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "cd '$1' && find . -type f $FIND_FILTER -print | tar -cf - -T -" ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; cd '$1' && find . -type f $FIND_FILTER -print | tar -cf - -T -" ;;
  esac
}

command -v tar >/dev/null 2>&1 || { echo "tar manquant sur tower" >&2; exit 1; }
mkdir -p "$MARKERS"

pull_dir() { # $1=source  $2=dossier distant
  local source="$1" remote="$2" dest="$ROOT/$source"
  local parent sub slug marker n
  if ! remote_is_dir "$remote"; then
    echo "  $remote : absent ou illisible, ignore"
    return 0
  fi
  local subs
  subs=$(remote_ls "$remote" 2>/dev/null | tr -d '\r' | grep -v '^\.\{1,2\}$' || true)
  [ -n "$subs" ] || { echo "  $remote : vide"; return 0; }

  if [ $DRY_RUN -eq 1 ]; then
    # Un `du` par entree couterait un aller-retour ssh PAR FICHIER (des heures
    # sur une galerie plate de plusieurs milliers de fichiers) : une seule
    # mesure du dossier suffit pour savoir ce qu'il reste a rapatrier.
    echo "  $remote : $(printf '%s\n' "$subs" | wc -l) entrees, $(remote_du "$remote" | tr -d '\r' | tr -d '\r')"
    return 0
  fi

  # Lot de N entrees par flux tar. Un flux par fichier (l'ancien
  # comportement) ajoutait un handshake ssh par photo : sur une galerie plate
  # de 7500 fichiers, l'overhead depassait le temps de transfert. Les marqueurs
  # restent unitaires (un par entree), donc un lot interrompu ne fait perdre
  # que ce lot, et une relance recalcule les lots a partir de ce qui manque.
  local batch=() names=()
  flush_batch() {
    [ ${#names[@]} -eq 0 ] && return 0
    mkdir -p "$dest"
    echo "  -> $remote : ${#names[@]} entree(s) de ${names[0]} a ${names[-1]}"
    if remote_tar "$remote" "${names[@]}" | tar -C "$dest" -xf -; then
      for n in "${batch[@]}"; do
        touch "$MARKERS/${source}-${n}"
      done
    else
      echo "     lot interrompu : relancer la meme commande pour reprendre" >&2
      batch=()
      names=()
      return 1
    fi
    batch=()
    names=()
    return 0
  }

  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    case "$sub" in
      *"'"*) echo "  $remote/$sub : apostrophe dans le nom, ignore" >&2 ; continue ;;
    esac
    slug=$(printf '%s' "$remote/$sub" | tr '/ ' '__')
    marker="$MARKERS/${source}-${slug}"
    if [ $FORCE -eq 0 ] && [ -f "$marker" ]; then
      continue
    fi
    batch+=("$slug")
    names+=("$sub")
    if [ ${#names[@]} -ge $BATCH ]; then
      flush_batch || return 1
    fi
  done <<<"$subs"
  flush_batch || return 1
  return 0
}

rc=0
for source in "${WANTED[@]}"; do
  echo "=== $source ==="
  [ -n "${REMOTE_PATHS[$source]:-}" ] || { echo "  source inconnue : $source" >&2; rc=1; continue; }
  for remote in ${REMOTE_PATHS[$source]}; do
    if [ "$ONLY" = all ]; then
      pull_dir "$source" "$remote" || rc=1
    else
      # Mode filtre : un seul flux par dossier distant, marqueur par (source,
      # dossier, mode) pour que photos et videos soient repris independamment.
      if ! remote_is_dir "$remote"; then
        echo "  $remote : absent ou illisible, ignore"
        continue
      fi
      slug=$(printf '%s' "$remote" | tr '/ ' '__')
      marker="$MARKERS/${source}-${slug}-${ONLY}"
      if [ $FORCE -eq 0 ] && [ -f "$marker" ]; then
        echo "  $remote ($ONLY) : deja rapatrie"
        continue
      fi
      if [ $DRY_RUN -eq 1 ]; then
        echo "  $remote ($ONLY) : filtre par extension, $(remote_du "$remote" | tr -d '\r') au total"
        continue
      fi
      mkdir -p "$ROOT/$source"
      echo "  -> $remote ($ONLY)"
      if remote_tar_filtered "$remote" | tar -C "$ROOT/$source" -xf -; then
        touch "$marker"
      else
        echo "     interrompu : relancer la meme commande pour reprendre" >&2
        rc=1
      fi
    fi
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
