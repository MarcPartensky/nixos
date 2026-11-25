#!/usr/bin/env python3
# modules/nixos/mcp-host/disable-stdio.py
#
# Eteint des serveurs MCP dans config.yaml APRES le merge de l'activation.
#
# Appele par system.activationScripts."hermes-mcp-host-takeover" avec deux
# arguments : le chemin de config.yaml et une liste JSON de noms.
#
# Pourquoi ce detour par l'activation plutot que Nix directement :
#   - definir `services.hermes-agent.mcpServers.<n>` dans le module qui LIT
#     cette meme option force la fusion complete de l'option pour connaitre les
#     noms, donc une boucle d'eval (`infinite recursion encountered`) ;
#   - ecrire `settings.mcp_servers.<n>.enabled` ne tient pas : la conversion
#     mcpServersToConfig reecrit tout `mcp_servers` a priorite normale et gagne.
# La liste des noms vient du Nix, donc le resultat est deterministe, et ce
# script ne fait rien d'autre que poser `enabled: false`.
import json
import os
import sys

import yaml


def main() -> int:
    path = sys.argv[1]
    names = json.loads(sys.argv[2])
    # Optional third argument: servers to DELETE outright (entry and config),
    # not just disable. Used for integrations marc dropped for good.
    purge = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
    if not names and not purge:
        return 0
    if not os.path.exists(path):
        print(f"[mcp-host] config.yaml absent ({path}), rien a eteindre", file=sys.stderr)
        return 0

    st = os.stat(path)
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
    servers = cfg.get("mcp_servers") or {}

    changed = []
    removed = [n for n in purge if servers.pop(n, None) is not None]
    for name in names:
        entry = servers.get(name)
        if not isinstance(entry, dict):
            # Entree absente : rien a faire, ce n'est pas une erreur (un
            # serveur peut avoir ete retire du fichier entre deux switches).
            continue
        if entry.get("enabled") is False:
            continue
        entry["enabled"] = False
        changed.append(name)

    if removed:
        print(f"[mcp-host] supprimes : {', '.join(removed)}", file=sys.stderr)
    if not changed and not removed:
        print(f"[mcp-host] {len(names)} serveurs deja eteints", file=sys.stderr)
    else:
        with open(path, "w") as f:
            yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
        # Le fichier appartient a l'utilisateur du service : on le rend tel
        # quel, sinon la prochaine ecriture par Hermes echoue.
        os.chmod(path, st.st_mode & 0o7777)
        os.chown(path, st.st_uid, st.st_gid)
        if changed:
            print(f"[mcp-host] eteints : {', '.join(changed)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
