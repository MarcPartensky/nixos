#!/usr/bin/env bash
# deploy/render.sh
# Rend un fichier quadlet podman pour un conteneur declare dans
# deploy/containers.nix, puis recharge systemd. Aucun nixos-rebuild.
#
#   sudo ./deploy/render.sh shlink-web-client --system   # sur tower, unite systeme
#   ./deploy/render.sh shlink-web-client                 # rootless, pour tester
#
# Le conteneur garde son nom : le quadlet remplace l'unite generee par
# virtualisation.oci-containers une fois le module retire (phase 2 de la
# migration, voir l'en-tete de deploy/containers.nix).
#
# Dependances volontairement limitees a bash, nix et python3 : jq n'est pas dans
# le PATH de l'agent sur tower.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
name=${1:?usage: render.sh <nom> [--system|--render-only|--takeover]}
mode=${2:-}
takeover=0
if [ "$mode" = "--takeover" ]; then
  # Reprise d'un conteneur encore gere par virtualisation.oci-containers :
  # on arrete et desactive l'unite nixos AVANT de demarrer le quadlet, sinon
  # les deux se disputent le meme nom de conteneur.
  takeover=1
  mode=--system
fi

if [ "$mode" = "--system" ]; then
  dir=/etc/containers/systemd
  scope=system
  wanted=multi-user.target
else
  dir=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
  scope=user
  wanted=default.target
fi

# Une seule eval, et uniquement la sortie deploy.containers du flake : la conf
# NixOS de l'hote n'est jamais evaluee.
# Sans --impure volontairement : cette sortie est pure (containers.nix n'est
# qu'un attrs d'attrs), donc l'eval est cacheable et passe de ~18 s a ~1 s une
# fois le cache chaud. --impure desactiverait ce cache.
json=$(nix eval --json "path:$repo#deploy.containers.$name")
mkdir -p "$dir"
unit=$dir/$name.container

# Le JSON passe par un fichier : `python3 - <<EOF` lit le PROGRAMME sur stdin,
# donc un pipe ne peut pas servir a la fois de code et de donnees.
printf '%s' "$json" >"$unit.json.tmp"
python3 - "$unit" "$wanted" "$unit.json.tmp" "$name" <<'PY'
import json, sys

spec = json.load(open(sys.argv[3]))
unit, wanted, name = sys.argv[1], sys.argv[2], sys.argv[4]
out = [
    "[Unit]",
    f"Description={spec.get('description') or spec['image']}",
]
# Ordre de demarrage : quadlet accepte les directives d'unite classiques.
for dep in spec.get("unitAfter") or []:
    out.append(f"After={dep}")
for dep in spec.get("unitRequires") or []:
    out.append(f"Requires={dep}")
out += [
    "",
    "[Container]",
    # Garde le nom du conteneur : `podman exec shlink` continue de marcher.
    f"ContainerName={name}",
    f"Image={spec['image']}",
]
for p in spec.get("publish") or []:
    out.append(f"PublishPort={p}")
# network = "host" pour un conteneur en network=host ; networks = ["nom", ...]
# pour joindre des reseaux podman nommes (plusieurs lignes Network=).
if spec.get("network"):
    out.append(f"Network={spec['network']}")
for n in spec.get("networks") or []:
    out.append(f"Network={n}")
if spec.get("user"):
    out.append(f"User={spec['user']}")
if spec.get("cmd"):
    out.append("Exec=" + " ".join(spec["cmd"]))
for k, v in (spec.get("env") or {}).items():
    out.append(f"Environment={k}={v}")
for f in spec.get("envFiles") or []:
    out.append(f"EnvironmentFile={f}")
for v in spec.get("volumes") or []:
    out.append(f"Volume={v}")
health = spec.get("health") or {}
if health.get("cmd"):
    out += [
        f"HealthCmd={health['cmd']}",
        f"HealthInterval={health.get('interval', '30s')}",
        f"HealthTimeout={health.get('timeout', '10s')}",
        f"HealthRetries={health.get('retries', 3)}",
    ]
out += spec.get("extraLines") or []
out += ["", "[Service]", "Restart=always", "", "[Install]", f"WantedBy={wanted}", ""]
open(unit + ".tmp", "w").write("\n".join(out))
PY

install -m 0644 "$unit.tmp" "$unit"
rm -f "$unit.tmp" "$unit.json.tmp"
echo "quadlet ecrit : $unit"

# Mode validation : rend le fichier et s'arrete la. Sert a verifier la syntaxe
# avec le generateur podman sans toucher a un conteneur qui tourne.
if [ "$mode" = "--render-only" ]; then
  exit 0
fi

field() { printf '%s' "$json" | python3 -c "import json,sys; s=json.load(sys.stdin); print($1)"; }

talk() { if [ "$scope" = system ]; then systemctl "$@"; else systemctl --user "$@"; fi; }

# Garde-fou sur les secrets : un fichier rendu par sops-nix absent signifie que
# la declaration sops a ete retiree de la conf hote trop tot. On echoue avant de
# redemarrer, plutot que de lancer un conteneur sans identifiants.
for f in $(field '"\n".join(s.get("envFiles") or [])'); do
  if [ ! -r "$f" ]; then
    echo "ERREUR: fichier d'environnement illisible: $f" >&2
    echo "        la declaration sops correspondante doit rester dans la conf hote." >&2
    exit 1
  fi
done

for n in $(field '"\n".join(s.get("networks") or [])'); do
  podman network exists "$n" 2>/dev/null || podman network create "$n" >/dev/null
done

if [ "$takeover" = 1 ]; then
  echo "reprise: arret de l'unite geree par NixOS (podman-$name.service)"
  talk disable --now "podman-$name.service" >/dev/null 2>&1 || true
  # Bind mounts uniquement : supprimer le conteneur ne touche pas aux donnees.
  podman rm -f "$name" >/dev/null 2>&1 || true
fi

talk daemon-reload
# pull explicite : un tag roulant (aonsoku:latest, shlink:stable) ne se met pas
# a jour tout seul.
podman pull -q "$(field 's["image"]')" >/dev/null
talk restart "$name.service"
talk --no-pager --lines=0 status "$name.service" || true
