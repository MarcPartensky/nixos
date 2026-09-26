# services/matrix-dumps/default.nix
# Copies en lecture seule des bases sqlite des ponts mautrix vers un dossier
# lisible par l'agent hermes : c'est ce qui permet à l'agent de LIRE les
# conversations (les salles Matrix des ponts sont chiffrées E2EE, les bases
# des ponts contiennent le texte en clair côté réseau d'origine).
#
# Rafraîchissement :
#   - au boot / à chaque switch (oneshot)
#   - à la demande : `touch /var/lib/hermes/.matrix/dumps/.refresh`
#     (systemd.path surveille ce fichier)
{
  pkgs,
  ...
}: let
  dumpDir = "/var/lib/hermes/.matrix/dumps";
in {
  systemd.tmpfiles.rules = ["d ${dumpDir} 0750 hermes hermes -"];

  systemd.services.matrix-dumps = {
    description = "Copie des bases sqlite des ponts mautrix (lecture par l'agent hermes)";
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
        # .backup = copie sqlite en ligne, cohérente même si le pont écrit
        ${pkgs.sqlite}/bin/sqlite3 "$db" ".backup '${dumpDir}/$name.tmp'"
        mv "${dumpDir}/$name.tmp" "${dumpDir}/$name"
        chown hermes:hermes "${dumpDir}/$name"
        chmod 0640 "${dumpDir}/$name"
      done
      # clés de pickle du store crypto : nécessaires pour déchiffrer les
      # sessions megolm (lecture des messages côté Matrix)
      for keyfile in /var/lib/mautrix-*/pickle_key.txt; do
        [ -f "$keyfile" ] || continue
        name=$(basename "$(dirname "$keyfile")")
        install -o hermes -g hermes -m 0400 "$keyfile" "${dumpDir}/$name-pickle-key.txt"
      done
    '';
  };

  # Déclencheur manuel : hermes (ou marc) touche .refresh, la copie se refait.
  systemd.paths.matrix-dumps-refresh = {
    wantedBy = ["multi-user.target"];
    pathConfig = {
      PathExists = "${dumpDir}/.refresh";
      Unit = "matrix-dumps.service";
    };
  };
}
