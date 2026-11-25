# services/matrix-dumps/default.nix
# Read-only copies of the mautrix bridges' sqlite databases to a folder
# readable by the hermes agent: this is what lets the agent READ the
# conversations (the bridges' Matrix rooms are E2EE-encrypted, the bridge
# databases contain the plaintext on the origin network side).
#
# Refresh:
#   - at boot / on each switch (oneshot)
#   - on demand: `touch /var/lib/hermes/.matrix/dumps/.refresh`
#     (systemd.path watches this file)
{
  pkgs,
  ...
}: let
  dumpDir = "/var/lib/hermes/.matrix/dumps";
in {
  systemd.tmpfiles.rules = ["d ${dumpDir} 0750 hermes hermes -"];

  systemd.services.matrix-dumps = {
    description = "Copy of the mautrix bridges' sqlite databases (read by the hermes agent)";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail
      rm -f ${dumpDir}/.refresh
      for db in /var/lib/mautrix-*/mautrix-*.db; do
        [ -f "$db" ] || continue
        name=$(basename "$db")
        # .backup = online sqlite copy, consistent even if the bridge is writing
        ${pkgs.sqlite}/bin/sqlite3 "$db" ".backup '${dumpDir}/$name.tmp'"
        mv "${dumpDir}/$name.tmp" "${dumpDir}/$name"
        chown hermes:hermes "${dumpDir}/$name"
        chmod 0640 "${dumpDir}/$name"
      done
      # crypto store pickle keys: needed to decrypt the
      # megolm sessions (reading messages on the Matrix side)
      for keyfile in /var/lib/mautrix-*/pickle_key.txt; do
        [ -f "$keyfile" ] || continue
        name=$(basename "$(dirname "$keyfile")")
        install -o hermes -g hermes -m 0400 "$keyfile" "${dumpDir}/$name-pickle-key.txt"
      done
    '';
  };

  # Manual trigger: hermes (or marc) touches .refresh, the copy is redone.
  systemd.paths.matrix-dumps-refresh = {
    wantedBy = ["multi-user.target"];
    pathConfig = {
      PathExists = "${dumpDir}/.refresh";
      Unit = "matrix-dumps.service";
    };
  };
}
