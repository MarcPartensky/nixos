#!/usr/bin/env python3
# modules/nixos/mcp-host/disable-stdio.py
#
# Turns off MCP servers in config.yaml AFTER the activation merge.
#
# Called by system.activationScripts."hermes-mcp-host-takeover" with two
# arguments: the path to config.yaml and a JSON list of names.
#
# Why this detour through activation rather than Nix directly:
#   - defining `services.hermes-agent.mcpServers.<n>` in the module that READS
#     this same option forces a full merge of the option to know the
#     names, hence an eval loop (`infinite recursion encountered`);
#   - writing `settings.mcp_servers.<n>.enabled` does not hold: the
#     mcpServersToConfig conversion rewrites all of `mcp_servers` at normal priority and wins.
# The list of names comes from Nix, so the result is deterministic, and this
# script does nothing other than set `enabled: false`.
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
        print(f"[mcp-host] config.yaml missing ({path}), nothing to turn off", file=sys.stderr)
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
            # Entry missing: nothing to do, this is not an error (a
            # server may have been removed from the file between two switches).
            continue
        if entry.get("enabled") is False:
            continue
        entry["enabled"] = False
        changed.append(name)

    if removed:
        print(f"[mcp-host] removed: {', '.join(removed)}", file=sys.stderr)
    if not changed and not removed:
        print(f"[mcp-host] {len(names)} servers already off", file=sys.stderr)
    else:
        with open(path, "w") as f:
            yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
        # The file belongs to the service user: we return it as
        # is, otherwise the next write by Hermes fails.
        os.chmod(path, st.st_mode & 0o7777)
        os.chown(path, st.st_uid, st.st_gid)
        if changed:
            print(f"[mcp-host] turned off: {', '.join(changed)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
