{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.btSink;

  stateDir = "/var/lib/bt-sink";
  recDir = "${stateDir}/rec";
  # marc n a pas d uid declare en dur : le relais deduit son runtime dir via id -u
  binPath = lib.makeBinPath [pkgs.bluez pkgs.pipewire pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.systemd];

  # Partie root : identite Bluetooth (Class of Device + nom) et pilotage du relais.
  # Appelee via sudo uniquement, cf. security.sudo.extraRules plus bas.
  rootHelper = pkgs.writeShellScriptBin "bt-sink-root" ''
    set -u
    export PATH=${binPath}:$PATH
    ADAPTER=${cfg.adapter}
    PATH_OBJ=/org/bluez/$ADAPTER
    STATE=${stateDir}

    get_class() {
      busctl --system get-property org.bluez $PATH_OBJ org.bluez.Adapter1 Class | cut -d' ' -f2
    }
    get_alias() {
      busctl --system get-property org.bluez $PATH_OBJ org.bluez.Adapter1 Alias | cut -d'"' -f2
    }
    status() {
      echo "adapter   : $ADAPTER"
      echo "class     : 0x$(printf '%06x' "$(get_class)")  (0x240418 = casque, 0x240414 = enceinte)"
      echo "nom       : $(get_alias)"
      echo "discoverable : $(busctl --system get-property org.bluez $PATH_OBJ org.bluez.Adapter1 Discoverable | cut -d' ' -f2)"
      echo "mode      : $(cat "$STATE/mode" 2>/dev/null || echo play)  (play | silent | replace:<fichier>)"
      echo "relais    : $(systemctl is-active bt-sink-relay 2>/dev/null || true)  /  agent : $(systemctl is-active bt-sink-agent 2>/dev/null || true)"
      echo "captures  : $(find "$STATE/rec" -name '*.raw' 2>/dev/null | wc -l) fichier(s) dans $STATE/rec"
    }

    case "''${1:-status}" in
      on)
        mkdir -p "$STATE/rec"
        if [ ! -f "$STATE/orig.class" ]; then
          get_class > "$STATE/orig.class"
          get_alias > "$STATE/orig.alias"
        fi
        hciconfig "$ADAPTER" class ${cfg.class} 2>&1 | sed 's/^/hciconfig: /' || true
        sleep 1
        echo "classe appliquee : 0x$(printf '%06x' "$(get_class)")"
        busctl --system set-property org.bluez $PATH_OBJ org.bluez.Adapter1 Alias s "${cfg.alias}"
        busctl --system set-property org.bluez $PATH_OBJ org.bluez.Adapter1 DiscoverableTimeout u 0
        busctl --system set-property org.bluez $PATH_OBJ org.bluez.Adapter1 Discoverable b true
        [ -s "$STATE/mode" ] || echo play > "$STATE/mode"
        systemctl start bt-sink-agent bt-sink-relay
        status
        ;;
      off)
        if [ -f "$STATE/orig.class" ]; then
          hciconfig "$ADAPTER" class "$(printf '0x%06x' "$(cat "$STATE/orig.class")")" || true
          busctl --system set-property org.bluez $PATH_OBJ org.bluez.Adapter1 Alias s "$(cat "$STATE/orig.alias" 2>/dev/null || echo deck)" || true
        fi
        busctl --system set-property org.bluez $PATH_OBJ org.bluez.Adapter1 Discoverable b false || true
        busctl --system set-property org.bluez $PATH_OBJ org.bluez.Adapter1 DiscoverableTimeout u 180 || true
        systemctl stop bt-sink-relay bt-sink-agent || true
        rm -f "$STATE/orig.class" "$STATE/orig.alias"
        status
        ;;
      mode)
        shift
        echo "''${*:-play}" > "$STATE/mode"
        echo "mode = $(cat "$STATE/mode")"
        ;;
      status) status ;;
      *)
        echo "usage: bt-sink-root [on|off|status|mode <play|silent|replace:/chemin/fichier>]" >&2
        exit 2
        ;;
    esac
  '';

  # Relais : attrape le flux A2DP entrant (bluez_input.*) et le pousse dans la
  # sortie par defaut du PipeWire de l'utilisateur, en le copiant au passage.
  relay = pkgs.writeShellScriptBin "bt-sink-relay" ''
    set -u
    export PATH=${binPath}:$PATH
    # lance par systemd avec User=marc : id -u donne 1000, et le socket
    # PipeWire de sa session vit dans /run/user/1000
    if [ ! -S "''${XDG_RUNTIME_DIR:-/nonexistent}/pipewire-0" ]; then
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
    STATE=${stateDir}

    log() { echo "bt-sink-relay: $*"; }

    seen="init"
    while :; do
      if ! dump=$(pw-dump 2>/dev/null); then
        log "pw-dump indisponible (XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-vide})"
        sleep 5
        continue
      fi
      all=$(printf '%s' "$dump" | grep -o '"node.name": "bluez_[^"]*"' | sed -e 's/.*: "//' -e 's/"$//' | sort -u | tr '\n' ' ')
      if [ "$all" != "$seen" ]; then
        log "noeuds bluez: ''${all:-aucun}"
        seen="$all"
      fi
      node=$(echo "$all" | tr ' ' '\n' | grep '^bluez_input' | head -n1)
      if [ -z "$node" ]; then
        sleep 2
        continue
      fi

      prof=$(printf '%s' "$dump" | grep -o '"api\.bluez5\.\(codec\|profile\)": "[^"]*"' | sort -u | tr '\n' ' ')
      log "transport : ''${prof:-non expose}"
      mode=$(cat "$STATE/mode" 2>/dev/null || echo play)
      out="$STATE/rec/$(date +%Y%m%dT%H%M%S)-a2dp-sink-48k-stereo-s16.raw"
      log "flux entrant sur $node, mode=$mode, capture=$out"

      case "$mode" in
        silent)
          pw-record --target="$node" --rate 48000 --channels 2 --format s16 - | tee -a "$out" > /dev/null
          ;;
        replace:*)
          file="''${mode#replace:}"
          if [ -r "$file" ]; then
            (
              while :; do
                pw-play --rate 48000 --channels 2 --format s16 "$file" || sleep 1
                sleep 0.2
              done
            ) &
            pid=$!
            pw-record --target="$node" --rate 48000 --channels 2 --format s16 - | tee -a "$out" > /dev/null
            kill "$pid" 2>/dev/null
          else
            log "fichier de remplacement illisible: $file, mode play"
            pw-record --target="$node" --rate 48000 --channels 2 --format s16 - | tee -a "$out" | pw-play --rate 48000 --channels 2 --format s16 -
          fi
          ;;
        *)
          pw-record --target="$node" --rate 48000 --channels 2 --format s16 - | tee -a "$out" | pw-play --rate 48000 --channels 2 --format s16 -
          ;;
      esac

      log "flux termine, $(stat -c %s "$out" 2>/dev/null || echo 0) octets dans $out"
      sleep 1
    done
  '';

  # Commande utilisateur (marc) : pas de root direct, tout passe par le helper.
  cli = pkgs.writeShellScriptBin "bt-sink" ''
    set -u
    export PATH=${binPath}:$PATH
    R=${rootHelper}/bin/bt-sink-root
    SUDO=/run/wrappers/bin/sudo
    STATE=${stateDir}

    case "''${1:-status}" in
      on|off)
        "$SUDO" -n "$R" "$1"
        ;;
      mode)
        shift
        "$SUDO" -n "$R" mode "$*"
        ;;
      status)
        "$R" status
        ;;
      play)
        f=$(ls -t "$STATE"/rec/*.raw 2>/dev/null | head -n1)
        if [ -z "''${f:-}" ]; then
          echo "aucune capture dans $STATE/rec" >&2
          exit 1
        fi
        echo "lecture de $f"
        pw-play --rate 48000 --channels 2 --format s16 "$f"
        ;;
      list|ls)
        ls -lht "$STATE"/rec 2>/dev/null | head -n 20
        ;;
      *)
        cat >&2 <<'EOF'
    usage: bt-sink <commande>

      on                       devient un faux casque Bluetooth (nom + classe casque,
                               discoverable, relais audio demarre)
      off                      restaure la classe et le nom d'origine
      status                   etat courant
      mode play                le flux recu sort par les enceintes (defaut)
      mode silent              le flux est seulement enregistre
      mode replace:/chemin.raw le flux recu est enregistre, et c'est ce fichier
                               qui sort par les enceintes
      list                     captures disponibles
      play                     rejoue la derniere capture
    EOF
        exit 2
        ;;
    esac
  '';
in {
  options.services.btSink = {
    enable = lib.mkEnableOption "faux casque Bluetooth (recepteur A2DP)";
    user = lib.mkOption {
      type = lib.types.str;
      default = "marc";
      description = "Utilisateur dont la session PipeWire recoit le son.";
    };
    adapter = lib.mkOption {
      type = lib.types.str;
      default = "hci0";
    };
    alias = lib.mkOption {
      type = lib.types.str;
      default = "AirPods Pro";
      description = "Nom annonce pendant le deguisement.";
    };
    class = lib.mkOption {
      type = lib.types.str;
      default = "0x240418";
      description = "Class of Device (0x240418 casque, 0x240414 enceinte).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cli rootHelper];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${recDir} 0755 ${cfg.user} users -"
      "f ${stateDir}/mode 0664 root ${cfg.user} -"
    ];

    systemd.services.bt-sink-relay = {
      description = "Relais A2DP sink (audio Bluetooth entrant vers les enceintes + capture)";
      after = ["bluetooth.service"];
      # demarre a la demande par bt-sink on, pas au boot
      wantedBy = [];
      serviceConfig = {
        User = cfg.user;
        ExecStart = "${relay}/bin/bt-sink-relay";
        Restart = "always";
        RestartSec = 3;
      };
    };

    # Agent d appairage sans interaction (Just Works) : sans agent enregistre,
    # bluetoothd refuse un appairage initie par le telephone.
    systemd.services.bt-sink-agent = {
      description = "Agent d appairage Bluetooth pour bt-sink (NoInputNoOutput)";
      after = ["bluetooth.service"];
      wantedBy = [];
      serviceConfig = {
        ExecStart = "${pkgs.bluez-tools}/bin/bt-agent --capability=NoInputNoOutput";
        Restart = "always";
        RestartSec = 3;
      };
    };

    security.sudo.extraRules = [
      {
        users = [cfg.user "hermes"];
        commands = [
          {
            command = "${rootHelper}/bin/bt-sink-root";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
