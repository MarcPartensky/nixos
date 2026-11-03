# services/android-capture/default.nix
# Capture reseau des Android emules sur tower, isolee par cible.
#
# POURQUOI au niveau reseau et pas via un proxy : un proxy ne voit que ce qui
# accepte de passer par lui. QUIC, Google Play Services et les SDK qui parlent
# en direct lui echappent. La capture au niveau de l'interface voit tout, y
# compris le chiffre, mais sans le contenu (TLS) : c'est du metadonnee, pas du
# clair. Pour le clair il faut un proxy avec un certificat de confiance, ce qui
# est un autre sujet.
#
# COMMENT ON ISOLE UNE APPLI : une cible = une instance Android, donc une
# interface et des pcaps a elle. C'est la seule isolation franche, et elle ne
# demande aucun root : l'instance A ne peut pas apparaitre dans les fichiers de
# l'instance B. Mettre une appli par instance (une AVD pour l'appli de travail,
# le conteneur Waydroid pour une autre) donne donc un pcap par appli.
#
# Ce qui ne marche PAS pour isoler sans root sur une meme instance : separer les
# pcaps par appli. Les applis d'un conteneur partagent un seul namespace reseau,
# tout arrive melange sur le bridge. Android sait rattacher chaque socket a un
# uid (`dumpsys netstats` pour les volumes par paquet, `/proc/net/tcp` pour l'uid
# de chaque connexion vivante), ce qui permet d'attribuer les flux d'un pcap aux
# applis par jointure sur les ports, mais c'est une reconstitution, pas une
# capture separee. Une capture par uid demande de marquer en iptables avec
# `-m owner --uid-owner <uid> -j NFLOG --nflog-group N` puis de capturer sur
# `nflog:N`, donc root dans l'instance.
#
# POURQUOI pas root cote hote : un tcpdump n'a besoin que de CAP_NET_RAW (et
# CAP_NET_ADMIN pour la capture en mode promiscue sur un bridge). On donne ces
# deux capacites au process par AmbientCapabilities, ce qui est plus etroit que
# de faire tourner la capture en root. Corollaire : NoNewPrivileges doit rester a
# false, systemd refuse la combinaison AmbientCapabilities + NoNewPrivileges.
# L'utilisateur est statique (pas DynamicUser) parce que plusieurs unites
# partagent le meme arbre d'etat : avec des uid transitoires, chaque demarrage
# reattribuerait les dossiers.
#
# CIBLES ALIMENTEES PAR UN EMULATEUR : un AVD sort par la pile reseau de l'hote,
# il n'a donc pas d'interface a capturer. On lui declare une liste d'interfaces
# vide : le module cree le dossier et le digest, et c'est le `-tcpdump` de
# l'emulateur qui ecrit dedans, par exemple
#   NIX_ANDROID_EMULATOR_FLAGS="... -tcpdump /var/lib/android-capture/pcap/avd/emu.pcap"
# Les dossiers de cible sont en 0770 pour que l'utilisateur qui lance l'emulateur
# (hermes) puisse y ecrire, alors que les pcaps restent au groupe.
#
# LIRE LE RESULTAT :
#   ls /var/lib/android-capture/pcap/<cible>/            # fichiers de 10 min, 12 h d'historique
#   cat /var/lib/android-capture/digest/<cible>.txt      # hotes du dernier fichier
#   cat /var/lib/android-capture/digest/<cible>-all.txt  # hotes vus, cumules
#   tshark -r <fichier>.pcap -Y 'tls.handshake.extensions_server_name' \
#       -T fields -e tls.handshake.extensions_server_name | sort -u
#
# DEPENDANCE : l'interface waydroid0 n'existe que si waydroid-container tourne.
# BindsTo lie le cycle de vie, pour ne pas laisser tcpdump echouer en boucle
# Android arrete.
{ pkgs, lib, ... }:
let
  # Une cible par instance Android. La liste d'interfaces est celle de l'hote :
  # vide = alimentee par le -tcpdump d'un emulateur.
  captures = {
    waydroid = [ "waydroid0" ];
    avd = [ ];
  };

  # Rotation : un fichier toutes les 10 minutes, 72 conserves, soit 12 h.
  rotateSeconds = 600;
  rotateKeep = 72;

  user = "android-capture";
  stateDir = "/var/lib/android-capture";

  # tcpdump ecrit des fichiers horodates et ecrase les plus vieux quand la
  # limite -W est atteinte.
  captureScript = target: ifaces: pkgs.writeShellScript "android-capture-${target}" ''
    set -eu
    exec ${pkgs.tcpdump}/bin/tcpdump \
      ${lib.concatMapStringsSep " " (i: "-i ${i}") ifaces} \
      -s 0 -w "${stateDir}/pcap/${target}/%Y%m%d-%H%M%S.pcap" \
      -G ${toString rotateSeconds} -W ${toString rotateKeep}
  '';

  # Digest par cible : resume du dernier fichier ecrit sous un nom stable, plus
  # une liste cumulee des hotes deja vus. Sert a repondre « cette appli parle a
  # qui » sans ouvrir wireshark, et a reperer un SDK qui reapparait. Le fichier
  # brut est dedoublonne a chaque passage, donc il ne grossit pas sans fin.
  digestScript = target: pkgs.writeShellScript "android-capture-digest-${target}" ''
    set -eu
    dir="${stateDir}/pcap/${target}"
    out="${stateDir}/digest"
    latest=$(ls -1t "$dir"/*.pcap 2>/dev/null | head -1 || true)
    [ -n "$latest" ] || { echo "${target}: aucun pcap pour l'instant"; exit 0; }

    ${pkgs.tshark}/bin/tshark -r "$latest" \
      -Y 'dns.flags.response==0 or tls.handshake.extensions_server_name' \
      -T fields -e dns.qry.name -e tls.handshake.extensions_server_name 2>/dev/null \
      | tr '\t' '\n' | grep -v '^$' | sort -u > "$out/${target}.txt.new"
    mv "$out/${target}.txt.new" "$out/${target}.txt"

    cat "$out/${target}.txt" >> "$out/${target}-all.raw"
    sort -u "$out/${target}-all.raw" > "$out/${target}-all.txt"
    sort -u "$out/${target}-all.raw" > "$out/${target}-all.raw.new"
    mv "$out/${target}-all.raw.new" "$out/${target}-all.raw"
    echo "${target}: $latest"
  '';

  hardening = {
    User = user;
    Group = user;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ReadWritePaths = [ stateDir ];
  };
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = stateDir;
    description = "Capture reseau Android";
  };
  users.groups.${user} = { };

  # marc doit pouvoir lire les captures sans root, et hermes aussi pour lancer
  # les emulateurs qui ecrivent dedans. Les dossiers restent en 0770 : lecture et
  # ecriture pour le groupe, rien pour les autres. Appartenir a un groupe ne
  # prend effet qu'a la prochaine ouverture de session (ou `newgrp`).
  users.users.marc.extraGroups = [ user ];
  users.users.hermes.extraGroups = [ user ];

  systemd.tmpfiles.rules =
    [
      "d ${stateDir} 0750 ${user} ${user} -"
      "d ${stateDir}/digest 0770 ${user} ${user} -"
    ]
    ++ lib.mapAttrsToList
      (target: _: "d ${stateDir}/pcap/${target} 0770 ${user} ${user} -")
      captures;

  # Une unite de capture par cible qui a une interface hote, plus un digest et un
  # timer par cible. Une seule affectation a systemd.services : deux clefs
  # identiques dans le meme attrebat seraient une erreur d'evaluation.
  systemd.services =
    lib.mapAttrs'
      (target: ifaces:
        lib.nameValuePair "android-capture-${target}" {
          description = "Capture reseau Android (${target})";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ]
            ++ lib.optional (builtins.elem "waydroid0" ifaces) "waydroid-container.service";
          bindsTo = lib.optional (builtins.elem "waydroid0" ifaces) "waydroid-container.service";
          serviceConfig = hardening // {
            ExecStart = "${captureScript target ifaces}";
            Restart = "on-failure";
            RestartSec = "10s";
            AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
            CapabilityBoundingSet = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
            # Obligatoire pour que les capacites ambiantes prennent effet.
            NoNewPrivileges = false;
          };
        })
      (lib.filterAttrs (_: ifaces: ifaces != [ ]) captures)
    // lib.mapAttrs'
      (target: _:
        lib.nameValuePair "android-capture-digest-${target}" {
          description = "Digest des hotes contactes (${target})";
          serviceConfig = hardening // {
            Type = "oneshot";
            ExecStart = "${digestScript target}";
          };
        })
      captures;

  systemd.timers = lib.mapAttrs'
    (target: _:
      lib.nameValuePair "android-capture-digest-${target}" {
        description = "Digest periodique de la capture Android (${target})";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "10min";
          Unit = "android-capture-digest-${target}.service";
        };
      })
    captures;
}
