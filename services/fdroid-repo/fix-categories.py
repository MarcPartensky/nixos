#!/usr/bin/env python3
# Corrige la categorie par defaut des squelettes de metadonnees crees par
# `fdroid update --create-metadata` : fdroid prend le nom du dossier courant
# comme categorie (ici "fdroid"), qui n'est pas une categorie F-Droid valide.
# On la remplace par une categorie valide, puis le service regenere l'index.
# Les fichiers deja edites a la main (categorie differente) ne sont pas touches.
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
