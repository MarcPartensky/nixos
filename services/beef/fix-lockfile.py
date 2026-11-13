#!/usr/bin/env python3
"""Ramene Gemfile.lock a la plateforme `ruby`.

Le lockfile upstream ne liste que des variantes precompilees
(x86_64-linux-gnu, aarch64-linux-musl, arm64-darwin...) : au demarrage,
bundler cherche ces variantes parmi les gems installes, or nixpkgs construit
les gems generiques, d'ou « Could not find sqlite3-2.10.2-x86_64-linux-gnu in
locally installed gems » (Bundler::GemNotFound) et un service en boucle
d'echec. On remet les specs sur la version generique et on reduit la section
PLATFORMS a `ruby`, ce qui correspond exactement a ce que bundlerEnv fournit.

Ne pas remplacer ce script par une desactivation de bundler : loader.rb ne
charge la plupart des gems que par Bundler.require(:default) (sinatra, sqlite3,
activerecord...), donc sauter bundler casse BeEF a l'import de Sinatra::Base.
"""

import re
import sys

PLATFORM_RE = re.compile(
    r"^    (?P<name>[\w.-]+) \((?P<version>[0-9][^)]*?)-"
    r"(?:x86_64|aarch64|arm64|arm|universal|java|jruby)[^)]*\)$"
)

path = sys.argv[1]
text = open(path).read()

# 1. Specs : version generique, et une seule entree par gem (le meme gem
# apparait une fois par variante de plateforme, avec ses dependances).
lines = []
seen = set()
skipping = False
for line in text.splitlines():
    match = PLATFORM_RE.match(line)
    if match:
        normalized = "    %s (%s)" % (match.group("name"), match.group("version"))
        if normalized.strip() in seen:
            skipping = True  # entree deja gardee : sauter aussi ses deps
            continue
        seen.add(normalized.strip())
        skipping = False
        lines.append(normalized)
        continue
    if skipping and line.startswith("      "):
        continue
    skipping = False
    lines.append(line)
text = "\n".join(lines) + "\n"

# 2. PLATFORMS : ne garder que `ruby`, sinon bundler reclame une gem valide
# pour toutes les plateformes listees a la fois.
text = re.sub(r"^PLATFORMS\n(?:  \S+\n)+", "PLATFORMS\n  ruby\n", text,
              flags=re.M)

open(path, "w").write(text)
