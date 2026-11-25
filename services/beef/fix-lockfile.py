#!/usr/bin/env python3
"""Brings Gemfile.lock back to the `ruby` platform.

The upstream lockfile lists only precompiled variants
(x86_64-linux-gnu, aarch64-linux-musl, arm64-darwin...): at startup,
bundler looks for these variants among the installed gems, but nixpkgs builds
the generic gems, hence "Could not find sqlite3-2.10.2-x86_64-linux-gnu in
locally installed gems" (Bundler::GemNotFound) and a service in a loop
of failure. We put the specs back on the generic version and reduce the
PLATFORMS section to `ruby`, which corresponds exactly to what bundlerEnv provides.

Do not replace this script with a disabling of bundler: loader.rb
loads most of the gems only through Bundler.require(:default) (sinatra, sqlite3,
activerecord...), so skipping bundler breaks BeEF at the import of Sinatra::Base.
"""

import re
import sys

PLATFORM_RE = re.compile(
    r"^    (?P<name>[\w.-]+) \((?P<version>[0-9][^)]*?)-"
    r"(?:x86_64|aarch64|arm64|arm|universal|java|jruby)[^)]*\)$"
)

path = sys.argv[1]
text = open(path).read()

# 1. Specs: generic version, and a single entry per gem (the same gem
# appears once per platform variant, with its dependencies).
lines = []
seen = set()
skipping = False
for line in text.splitlines():
    match = PLATFORM_RE.match(line)
    if match:
        normalized = "    %s (%s)" % (match.group("name"), match.group("version"))
        if normalized.strip() in seen:
            skipping = True  # entry already kept: skip its deps too
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

# 2. PLATFORMS: keep only `ruby`, otherwise bundler demands a valid gem
# for all the listed platforms at once.
text = re.sub(r"^PLATFORMS\n(?:  \S+\n)+", "PLATFORMS\n  ruby\n", text,
              flags=re.M)

open(path, "w").write(text)
