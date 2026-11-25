#!/usr/bin/env python3
# Fixes the default category of the metadata skeletons created by
# `fdroid update --create-metadata`: fdroid takes the name of the current directory
# as the category (here "fdroid"), which is not a valid F-Droid category.
# We replace it with a valid category, then the service regenerates the index.
# Files already edited by hand (different category) are not touched.
import pathlib
import sys

METADATA = pathlib.Path("/var/lib/fdroid/metadata")
PLACEHOLDER = ("Categories:\n- fdroid\n",)
FALLBACK = "Categories:\n- System\n"


def main() -> int:
    changed = []
    for path in sorted(METADATA.glob("*.yml")):
        text = path.read_text()
        if PLACEHOLDER[0] in text:
            path.write_text(text.replace(PLACEHOLDER[0], FALLBACK))
            changed.append(path.name)
    if changed:
        print(" ".join(changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
