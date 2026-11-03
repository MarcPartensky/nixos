{ config, lib, pkgs, ... }:

# Accès SSH de hermes vers le téléphone (modèle tmate : le tel sort vers le VPS
# `rack`, aucun port ouvert, aucun tiers, pas d'app VPN en plus).
#
#   - sshd local (port 8023, clé hermes@tower autorisée, sftp) ;
#   - `phone-tunnel-loop` : boucle `ssh -R 127.0.0.1:2224:127.0.0.1:8023 root@marcpartensky.com` ;
#   - `phone-up` : démarrage idempotent (sshd + tunnel + watchdog + wake-lock borné),
#     accroché à chaque session (.zprofile/.zshrc/.profile/.bashrc) ET à chaque prompt
#     zsh (precmd rate-limité 60s : n'importe quelle touche dans l'app répare) ;
#   - `phone-watchdog` : rejoue `phone-up` toutes les 2 min (filet de sécurité) ;
#   - `phone-update` : met à jour la conf (switch nix-on-droid, tarball-ttl 0) ;
#   - `phone-status` : diagnostic (verdicts + pids + logs).
#
# IMPORTANT (fiabilité Xiaomi/HyperOS) : accorder à l'app Nix la permission
# « Afficher des fenêtres pop-up en arrière-plan » (display over other apps),
# sinon le wake-lock échoue et MIUI tue les process d'arrière-plan.
#
# La clé privée du tunnel vit uniquement sur le tel (~/.ssh/relay_ed25519), jamais ici.
# Côté rack, l'entrée restreinte :
#   command="false",restrict,port-forwarding,permitlisten="127.0.0.1:2224" ssh-ed25519 AAAA... phone-relay

let
  inherit (config.user) home;

  # Le nixpkgs de nix-on-droid (inputs.nix-on-droid.inputs.nixpkgs) est ancien :
  # `pkgs.wstunnel` y est en 0.5.1.0, une version qui n'a ni `client` ni `-R`.
  # On prend donc celui d'unstable, comme pour tout paquet absent du nixpkgs
  # épinglé par le profil.
  wsTunnelPkg = inputs.unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.wstunnel;

  sshdDir = "${home}/sshd";
  sshdPort = 8023;

  relayHost = "marcpartensky.com";
  relayPort = 2224;
  relayKey = "${home}/.ssh/relay_ed25519";

  # Clés autorisées sur le sshd du téléphone.
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
  ];

  sshdConfig = pkgs.writeText "phone-sshd_config" ''
    Port ${toString sshdPort}
    ListenAddress 0.0.0.0
    HostKey ${sshdDir}/ssh_host_ed25519_key
    PidFile ${sshdDir}/sshd.pid
    AuthorizedKeysFile ${home}/.ssh/authorized_keys
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    AllowUsers ${config.user.userName}
    StrictModes no
    PrintMotd no
    Subsystem sftp internal-sftp
  '';

  authorizedKeysFile = pkgs.writeText "phone-authorized_keys"
    (lib.concatStringsSep "\n" authorizedKeys + "\n");

  tunnelLoop = pkgs.writeScriptBin "phone-tunnel-loop" ''
    #!${pkgs.runtimeShell}
    while true; do
      ${pkgs.openssh}/bin/ssh -NT \
        -i ${relayKey} \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
        -o ServerAliveInterval=25 -o ServerAliveCountMax=4 \
        -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=${home}/.ssh/known_hosts \
        -R 127.0.0.1:${toString relayPort}:127.0.0.1:${toString sshdPort} \
        root@${relayHost}
      ${pkgs.coreutils}/bin/sleep 15
    done
  '';

  # Tunnel WebSocket (wstunnel) : publie sur le VPS le sshd du téléphone
  # (127.0.0.1:2225) plus deux proxys sur sa boucle locale, un SOCKS5 (1081) et
  # un proxy HTTP (1082). Les requêtes qui passent par là sortent avec l'IP du
  # téléphone, pas celle de tower, et tout ça traverse du wss ordinaire, donc
  # ça survit à un réseau qui ne laisse sortir que du 443. Les ports d'écoute
  # vivent sur la boucle locale du VPS (services/wstunnel) puis sont relayés
  # par le client de tower.
  wsLoop = pkgs.writeScriptBin "phone-wstunnel-loop" ''
    #!${pkgs.runtimeShell}
    while true; do
      ${wsTunnelPkg}/bin/wstunnel client \
        -R tcp://127.0.0.1:2225:127.0.0.1:${toString sshdPort} \
        -R socks5://127.0.0.1:1081 \
        -R http://127.0.0.1:1082 \
        wss://ws.marcpartensky.com
      ${pkgs.coreutils}/bin/sleep 15
    done
  '';

  phoneUp = pkgs.writeScriptBin "phone-up" ''
    #!${pkgs.runtimeShell}
    core=${pkgs.coreutils}/bin
    flock=${lib.getBin pkgs.util-linux}/bin/flock
    $core/mkdir -p ${sshdDir}
    lock=${sshdDir}/up.lock
    running=${sshdDir}/up.running
    exec 9>>"$lock" || exit 0
    if [ -x "$flock" ]; then
      if ! "$flock" -n 9; then
        # Verrou deja pris : si le porteur (up.running, sinon mtime du verrou)
        # n'avance plus depuis 15 min, il est fige -> on le contourne en
        # recreant le verrou sur un inode neuf (le fige garde l'ancien).
        rts=$($core/stat -c %Y "$running" 2>/dev/null || echo 0)
        [ "$rts" -eq 0 ] && rts=$($core/stat -c %Y "$lock" 2>/dev/null || echo 0)
        now=$($core/date +%s)
        if [ "$rts" -gt 0 ] && [ "$((now - rts))" -gt 900 ]; then
          $core/rm -f "$lock"
          exec 9>>"$lock" || exit 0
          "$flock" -n 9 || exit 0
        else
          exit 0
        fi
      fi
    fi
    $core/touch "$running"
    trap '$core/rm -f "$running"' EXIT

    alive() {
      [ -f "$1" ] && kill -0 "$($core/cat "$1" 2>/dev/null)" 2>/dev/null
    }

    # 1) sshd (retries : le demarrage peut echouer sur un port encore occupe)
    if alive ${sshdDir}/sshd.pid; then
      :
    else
      $core/rm -f ${sshdDir}/sshd.pid
      n=0
      while [ "$n" -lt 3 ]; do
        n=$((n + 1))
        ${pkgs.openssh}/bin/sshd -f ${sshdDir}/sshd_config >> ${sshdDir}/up.log 2>&1
        $core/sleep 1
        if alive ${sshdDir}/sshd.pid; then
          echo "[up $(date 2>/dev/null)] sshd demarre (essai $n)" >> ${sshdDir}/up.log
          break
        fi
        $core/sleep 2
      done
      if ! alive ${sshdDir}/sshd.pid; then
        echo "[up $(date 2>/dev/null)] ECHEC sshd apres 3 essais" >> ${sshdDir}/up.log
      fi
    fi

    # 2) tunnel inverse (nécessite la clé posée au bootstrap)
    if alive ${sshdDir}/tunnel.pid; then
      :
    elif [ -f ${relayKey} ]; then
      $core/rm -f ${sshdDir}/tunnel.pid
      $core/nohup ${tunnelLoop}/bin/phone-tunnel-loop >> ${sshdDir}/tunnel.log 2>&1 &
      echo $! > ${sshdDir}/tunnel.pid
    fi

    # 2b) tunnel WebSocket (wstunnel) : indépendant du tunnel SSH, c'est le
    # chemin qui passe un réseau qui ne laisse sortir que le 443, et il porte
    # aussi les proxys SOCKS5/HTTP qui sortent avec l'IP du téléphone.
    if alive ${sshdDir}/wstunnel.pid; then
      :
    else
      $core/rm -f ${sshdDir}/wstunnel.pid
      $core/nohup ${wsLoop}/bin/phone-wstunnel-loop >> ${sshdDir}/wstunnel.log 2>&1 &
      echo $! > ${sshdDir}/wstunnel.pid
    fi

    # 3) watchdog : rejoue phone-up en boucle (relance ce qui est mort)
    if alive ${sshdDir}/watchdog.pid; then
      :
    else
      $core/rm -f ${sshdDir}/watchdog.pid
      $core/nohup ${phoneWatchdog}/bin/phone-watchdog >> ${sshdDir}/watchdog.log 2>&1 &
      echo $! > ${sshdDir}/watchdog.pid
    fi

    # 4) wake lock (anti-veille Android ; permission « fenêtres pop-up » requise).
    # DÉTACHÉ (nohup, jamais attendu) : l'appel am peut se figer sans fin (vécu :
    # `timeout 8` ne le tue pas, il tenait up.lock pour toujours et bloquait
    # silencieusement TOUTES les relances suivantes).
    wl=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/termux-wake-lock
    if [ -x "$wl" ]; then
      $core/nohup "$wl" >/dev/null 2>&1 &
    fi
  '';

  phoneWatchdog = pkgs.writeScriptBin "phone-watchdog" ''
    #!${pkgs.runtimeShell}
    while true; do
      ${pkgs.coreutils}/bin/sleep 120
      /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up || true
    done
  '';

  phoneUpdate = pkgs.writeScriptBin "phone-update" ''
    #!${pkgs.runtimeShell}
    export PATH=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin:$PATH
    cd ${home}
    exec nix-on-droid switch --flake "git+https://github.com/MarcPartensky/nixos" --option tarball-ttl 0
  '';

  phoneStatus = pkgs.writeScriptBin "phone-status" ''
    #!${pkgs.runtimeShell}
    check() {
      if [ -f "$2" ] && kill -0 "$(cat "$2" 2>/dev/null)" 2>/dev/null; then
        echo "$1: UP (pid $(cat "$2"))"
      else
        echo "$1: DOWN"
      fi
    }
    check sshd ${sshdDir}/sshd.pid
    check tunnel ${sshdDir}/tunnel.pid
    check watchdog ${sshdDir}/watchdog.pid
    check wstunnel ${sshdDir}/wstunnel.pid
    echo "== tunnel.log (5 dernieres lignes)"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/tunnel.log 2>/dev/null || true
    echo "== up.log (5 dernieres lignes)"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/up.log 2>/dev/null || true
    echo "== wstunnel.log (5 dernieres lignes)"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/wstunnel.log 2>/dev/null || true
  '';
in
{
  environment.packages = with pkgs; [
    openssh
    util-linux # flock pour phone-up
    gnugrep # pratique en session de debug
    tunnelLoop # référencés ici -> installés sur le tel
    wsLoop
    wsTunnelPkg # client du tunnel WebSocket (10.x, cf. commentaire dans le let)
    phoneUp
    phoneWatchdog
    phoneUpdate
    phoneStatus
  ];

  android-integration = {
    termux-wake-lock.enable = true;
    termux-wake-unlock.enable = true;
    termux-setup-storage.enable = true;
    termux-open.enable = true;
    termux-open-url.enable = true;
    am.enable = true;
  };

  build.activation = {
    sshd = ''
      $DRY_RUN_CMD mkdir -p ${sshdDir}
      if [ ! -f ${sshdDir}/ssh_host_ed25519_key ]; then
        $VERBOSE_ECHO "phone: generating sshd host key"
        $DRY_RUN_CMD ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f ${sshdDir}/ssh_host_ed25519_key
      fi
      $VERBOSE_ECHO "phone: installing sshd_config + authorized_keys"
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p ${home}/.ssh
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 700 ${home}/.ssh
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 600 ${sshdConfig} ${sshdDir}/sshd_config
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 600 ${authorizedKeysFile} ${home}/.ssh/authorized_keys
    '';

    termuxProps = ''
      $DRY_RUN_CMD mkdir -p ${home}/.termux
      if [ -z "''${DRY_RUN:-}" ]; then
        if ! grep -qs allow-external-apps ${home}/.termux/termux.properties; then
          printf 'allow-external-apps=true\n' >> ${home}/.termux/termux.properties
        fi
      fi
    '';

    autostart = ''
      if [ -z "''${DRY_RUN:-}" ]; then
        for f in ${home}/.zprofile ${home}/.zshrc ${home}/.profile ${home}/.bashrc; do
          if ! grep -q nod-phone-autostart2 "$f" 2>/dev/null; then
            printf '\n# nod-phone-autostart2\nif [ -x /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up ]; then /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up >/dev/null 2>&1 || true; fi\n' >> "$f"
          fi
        done
        if ! grep -q nod-phone-autorepair3 ${home}/.zshrc 2>/dev/null; then
          printf '\n# nod-phone-autorepair3\nalias up="phone-up"\n_nod_autorepair() {\n  local p=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up\n  [ -x "$p" ] || return 0\n  local s="$HOME/sshd/.up-stamp" now last\n  now=$(date +%s 2>/dev/null) || return 0\n  last=0\n  [ -f "$s" ] && last=$(stat -c %%Y "$s" 2>/dev/null || echo 0)\n  if [ "$((now - last))" -gt 60 ]; then\n    : > "$s"\n    ( "$p" >/dev/null 2>&1 & )\n  fi\n}\nprecmd_functions+=(_nod_autorepair)\n' >> ${home}/.zshrc
        fi
      fi
    '';
  };
}
