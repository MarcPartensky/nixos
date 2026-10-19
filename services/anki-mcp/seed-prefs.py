#!/usr/bin/env python3
"""Crée le prefs21.db d'Anki s'il n'existe pas encore.

Anki considère `prefs21.db` absent comme « premier lancement » et affiche
alors un sélecteur de langue MODAL (aqt/__init__.py, `if firstTime:
pm.setDefaultLang()`), puis attend un clic. Sans écran, ce dialogue bloque
l'ouverture du profil : pas de collection, pas de serveur MCP. Les images
headless d'ankimcp contournent le problème en embarquant un prefs21.db
pré-configuré ; ici on le génère, ce qui reste lisible.

Contenu minimal attendu par Anki (aqt/profiles.py) : une base sqlite avec une
table `profiles`, et une ligne `_global` dont la colonne `data` est un dict
picklé. Les clés sont celles de `metaConf`, avec `firstRun` à False et
`defaultLang` renseigné (c'est ce dernier qui évite le sélecteur).

Le script est idempotent : il ne touche jamais un prefs21.db existant, donc
aucun risque d'écraser un réglage posé par Anki ensuite.
"""

import os
import pickle
import random
import sqlite3
import sys
import time

LANG = os.environ.get("ANKI_LANG", "en_US")


def main() -> int:
    path = sys.argv[1]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        return 0

    meta = {
        "ver": 0,
        "updates": True,
        "created": int(time.time()),
        "id": random.randrange(0, 2**63),
        "lastMsg": 0,
        "suppressUpdate": False,
        "firstRun": False,
        "defaultLang": LANG,
    }

    con = sqlite3.connect(path)
    con.execute(
        "create table if not exists profiles "
        "(name text primary key collate nocase, data blob not null)"
    )
    con.execute(
        "insert or replace into profiles values ('_global', ?)",
        (pickle.dumps(meta, protocol=4),),
    )
    con.commit()
    con.close()
    print(f"prefs21.db amorcé ({path}, langue {LANG})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
