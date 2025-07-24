#!/usr/bin/env python3

import json
import os
from subprocess import check_output, CalledProcessError

players = ["spotify", "vlc", "mpv", "cider"]

try:
    active_players = check_output(["playerctl", "-l"]).decode("utf-8").splitlines()
    for player in players:
        if player in active_players:
            status = check_output(["playerctl", "-p", player, "status"]).decode("utf-8").strip()
            metadata = check_output(["playerctl", "-p", player, "metadata", "--format", "{{ artist }} - {{ title }}"]).decode("utf-8").strip()
            print(json.dumps({
                "text": metadata,
                "class": status.lower(),
                "alt": player,
                "tooltip": status
            }))
            exit(0)
except CalledProcessError:
    pass

print(json.dumps({"text": "", "class": "stopped"}))
