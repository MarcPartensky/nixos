{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.btSink;

  stateDir = "/var/lib/bt-sink";
  recDir = "${stateDir}/rec";
  # marc has no hardcoded uid: the relay derives its runtime dir via id -u
  binPath = lib.makeBinPath [pkgs.bluez pkgs.pipewire pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.systemd];

  # Root part: Bluetooth identity (Class of Device + name) and relay control.
  # Called via sudo only, cf. security.sudo.extraRules further down.
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
      echo "class     : 0x$(printf '%06x' "$(get_class)")  (0x240418 = headset, 0x240414 = speaker)"
      echo "name      : $(get_alias)"
      echo "discoverable : $(busctl --system get-property org.bluez $PATH_OBJ org.bluez.Adapter1 Discoverable | cut -d' ' -f2)"
      echo "mode      : $(cat "$STATE/mode" 2>/dev/null || echo play)  (play | silent | replace:<file>)"
      echo "relay     : $(systemctl is-active bt-sink-relay 2>/dev/null || true)  /  agent : $(systemctl is-active bt-sink-agent 2>/dev/null || true)"
      echo "captures  : $(find "$STATE/rec" -name '*.raw' 2>/dev/null | wc -l) file(s) in $STATE/rec"
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
        echo "class applied: 0x$(printf '%06x' "$(get_class)")"
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
        echo "usage: bt-sink-root [on|off|status|mode <play|silent|replace:/path/file>]" >&2
        exit 2
        ;;
    esac
  '';

  # Relay: catches the incoming A2DP stream (bluez_input.*) and pushes it into
  # the user's default PipeWire output, copying it along the way.
  relay = pkgs.writeShellScriptBin "bt-sink-relay" ''
    set -u
    export PATH=${binPath}:$PATH
    # launched by systemd with User=marc: id -u gives 1000, and the
    # PipeWire socket of his session lives in /run/user/1000
    if [ ! -S "''${XDG_RUNTIME_DIR:-/nonexistent}/pipewire-0" ]; then
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
    STATE=${stateDir}

    log() { echo "bt-sink-relay: $*"; }

    seen="init"
    while :; do
      if ! dump=$(pw-dump 2>/dev/null); then
        log "pw-dump unavailable (XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-empty})"
        sleep 5
        continue
      fi
      all=$(printf '%s' "$dump" | grep -o '"node.name": "bluez_[^"]*"' | sed -e 's/.*: "//' -e 's/"$//' | sort -u | tr '\n' ' ')
      if [ "$all" != "$seen" ]; then
        log "bluez nodes: ''${all:-none}"
        seen="$all"
      fi
      node=$(echo "$all" | tr ' ' '\n' | grep '^bluez_input' | head -n1)
      if [ -z "$node" ]; then
        sleep 2
        continue
      fi

      prof=$(printf '%s' "$dump" | grep -o '"api\.bluez5\.\(codec\|profile\)": "[^"]*"' | sort -u | tr '\n' ' ')
      log "transport: ''${prof:-not exposed}"
      mode=$(cat "$STATE/mode" 2>/dev/null || echo play)
      out="$STATE/rec/$(date +%Y%m%dT%H%M%S)-a2dp-sink-48k-stereo-s16.raw"
      log "incoming stream on $node, mode=$mode, capture=$out"

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
            log "replacement file unreadable: $file, play mode"
            pw-record --target="$node" --rate 48000 --channels 2 --format s16 - | tee -a "$out" | pw-play --rate 48000 --channels 2 --format s16 -
          fi
          ;;
        *)
          pw-record --target="$node" --rate 48000 --channels 2 --format s16 - | tee -a "$out" | pw-play --rate 48000 --channels 2 --format s16 -
          ;;
      esac

      log "stream finished, $(stat -c %s "$out" 2>/dev/null || echo 0) bytes in $out"
      sleep 1
    done
  '';

  # User command (marc): no direct root, everything goes through the helper.
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
          echo "no capture in $STATE/rec" >&2
          exit 1
        fi
        echo "playing $f"
        pw-play --rate 48000 --channels 2 --format s16 "$f"
        ;;
      list|ls)
        ls -lht "$STATE"/rec 2>/dev/null | head -n 20
        ;;
      *)
        cat >&2 <<'EOF'
    usage: bt-sink <command>

      on                       becomes a fake Bluetooth headset (name + headset class,
                               discoverable, audio relay started)
      off                      restores the original class and name
      status                   current state
      mode play                the received stream plays through the speakers (default)
      mode silent              the stream is only recorded
      mode replace:/path.raw   the received stream is recorded, and it is this file
                               that plays through the speakers
      list                     available captures
      play                     replays the last capture
    EOF
        exit 2
        ;;
    esac
  '';
in {
  options.services.btSink = {
    enable = lib.mkEnableOption "fake Bluetooth headset (A2DP receiver)";
    user = lib.mkOption {
      type = lib.types.str;
      default = "marc";
      description = "User whose PipeWire session receives the sound.";
    };
    adapter = lib.mkOption {
      type = lib.types.str;
      default = "hci0";
    };
    alias = lib.mkOption {
      type = lib.types.str;
      default = "AirPods Pro";
      description = "Name announced during the disguise.";
    };
    class = lib.mkOption {
      type = lib.types.str;
      default = "0x240418";
      description = "Class of Device (0x240418 headset, 0x240414 speaker).";
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
      description = "A2DP sink relay (incoming Bluetooth audio to the speakers + capture)";
      after = ["bluetooth.service"];
      # started on demand by bt-sink on, not at boot
      wantedBy = [];
      serviceConfig = {
        User = cfg.user;
        ExecStart = "${relay}/bin/bt-sink-relay";
        Restart = "always";
        RestartSec = 3;
      };
    };

    # Interaction-free pairing agent (Just Works): without a registered agent,
    # bluetoothd refuses a pairing initiated by the phone.
    systemd.services.bt-sink-agent = {
      description = "Bluetooth pairing agent for bt-sink (NoInputNoOutput)";
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
