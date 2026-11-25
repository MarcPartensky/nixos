#!/usr/bin/env python3
"""postFixup fixer for upstream hermes-agent (run from services/hermes/default.nix).

secure_parent_dir() in hermes_constants.py chmods the parent of credential
files (the hermes home itself, since auth.json lives at its root) to 0700 on
every save, with no managed-install carve-out -- unlike apply_secure_dir_policy()
and ensure_private_store(), which both skip managed installs by design. On a
NixOS group-shared home (marc needs r-x, cf. the ACL rules in
profiles/tower/configuration.nix) each credential save silently re-locks the
home and cuts him off; observed live on 2026-11-25 02:06:59 (auth.json save,
mode 750 -> 700).

This script rewrites the installed file so secure_parent_dir() honors the same
carve-outs: managed installs (.managed marker / HERMES_MANAGED env) and
HERMES_HOME_MODE win. The anchor must match exactly once; otherwise the build
fails loudly instead of shipping a package without the fix (upstream bumps
that move the code are expected to break here on purpose).

Usage: python3 hermes-agent-managed-home.py <package-out-path>
"""

import glob
import os
import sys

OLD = """        return
    with contextlib.suppress(OSError):
        os.chmod(parent, 0o700)
"""

NEW = """        return
    # Managed installs and HERMES_HOME_MODE own the home mode: the same carve-outs as
    # apply_secure_dir_policy(). Without them, every credential save re-locks a
    # NixOS group-shared home to 0700, silently cutting off the extra group members.
    if get_managed_system() is not None:
        return
    explicit_mode = os.environ.get("HERMES_HOME_MODE", "").strip()
    try:
        mode = int(explicit_mode, 8) if explicit_mode else 0o700
    except ValueError:
        mode = 0o700
    with contextlib.suppress(OSError):
        os.chmod(parent, mode)
"""


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <package-out-path>")
    matches = glob.glob(
        f"{sys.argv[1]}/lib/python3*/site-packages/hermes_constants.py"
    )
    if len(matches) != 1:
        raise SystemExit(
            f"managed-home patch: expected exactly one hermes_constants.py under "
            f"{sys.argv[1]}/lib/python3*/site-packages, found {matches}"
        )
    path = matches[0]
    src = open(path).read()
    count = src.count(OLD)
    if count != 1:
        raise SystemExit(
            f"managed-home patch: anchor found {count} times in {path}, expected 1 "
            "(upstream moved secure_parent_dir; update the anchor)"
        )
    # $out copies installed from the store arrive read-only; we own the build tree.
    os.chmod(path, 0o644)
    with open(path, "w") as fh:
        fh.write(src.replace(OLD, NEW))
    print(f"managed-home patch applied to {path}")


if __name__ == "__main__":
    main()
