#!/usr/bin/env python3
"""Creates Anki's prefs21.db if it does not exist yet.

Anki treats a missing `prefs21.db` as a "first launch" and then shows a
MODAL language selector (aqt/__init__.py, `if firstTime:
pm.setDefaultLang()`), then waits for a click. Without a screen, that dialog
blocks opening the profile: no collection, no MCP server. The headless
ankimcp images work around the problem by embedding a pre-configured
prefs21.db; here we generate it, which stays readable.

Minimal content expected by Anki (aqt/profiles.py): a sqlite database with a
`profiles` table, and a `_global` row whose `data` column is a pickled dict.
The keys are those of `metaConf`, with `firstRun` set to False and
`defaultLang` filled in (it is the latter that avoids the selector).

The script is idempotent: it never touches an existing prefs21.db, so there
is no risk of overwriting a setting applied by Anki afterwards.
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
    print(f"prefs21.db seeded ({path}, language {LANG})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
