{ config, lib, pkgs, ... }:

# Accès SSH de hermes vers le téléphone (modèle tmate : le tel sort vers le VPS
# `rack`, aucun port ouvert, aucun tiers, pas d'app VPN en plus).
#
#   - sshd local (port 8023, clé hermes@tower autorisée, sftp) ;
#   - `phone-tunnel-loop` : boucle `ssh -R 127.0.0.1:2224:127.0.0.1:8023 root@marcpartensky.com` ;
#   - `phone-up` : démarrage idempotent (sshd + tunnel + wake-lock), accroché à chaque
#     session via ~/.zprofile, ~/.zshrc, ~/.profile et ~/.bashrc ;
#   - `phone-status` : diagnostic (pids + logs).
#
# La clé privée du tunnel vit uniquement sur le tel (~/.ssh/relay_ed25519), jamais ici.
# Côté rack, l'entrée restreinte :
#   command="false",restrict,port-forwarding,permitlisten="127.0.0.1:2224" ssh-ed25519 AAAA... phone-relay

let
  inherit (config.user) home;

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

  phoneUp = pkgs.writeScriptBin "phone-up" ''
    #!${pkgs.runtimeShell}
    core=${pkgs.coreutils}/bin
    flock=${lib.getBin pkgs.util-linux}/bin/flock
    $core/mkdir -p ${sshdDir}
    lock=${sshdDir}/up.lock
    exec 9>"$lock" || exit 0
    if [ -x "$flock" ]; then "$flock" -n 9 || exit 0; fi

    # 1) sshd
    if [ -f ${sshdDir}/sshd.pid ] && kill -0 "$($core/cat ${sshdDir}/sshd.pid)" 2>/dev/null; then
      :
    else
      $core/rm -f ${sshdDir}/sshd.pid
      ${pkgs.openssh}/bin/sshd -f ${sshdDir}/sshd_config >> ${sshdDir}/up.log 2>&1 || true
    fi

    # 2) tunnel inverse (nécessite la clé posée au bootstrap)
    if [ -f ${sshdDir}/tunnel.pid ] && kill -0 "$($core/cat ${sshdDir}/tunnel.pid)" 2>/dev/null; then
      :
    elif [ -f ${relayKey} ]; then
      $core/rm -f ${sshdDir}/tunnel.pid
      $core/nohup ${tunnelLoop}/bin/phone-tunnel-loop >> ${sshdDir}/tunnel.log 2>&1 &
      echo $! > ${sshdDir}/tunnel.pid
    fi

    # 3) wake lock (anti-gel Android ; demande la permission "superposition d'écran")
    wl=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/termux-wake-lock
    if [ -x "$wl" ]; then
      "$wl" || true
    fi
  '';

  phoneStatus = pkgs.writeScriptBin "phone-status" ''
    #!${pkgs.runtimeShell}
    echo "== sshd"
    if [ -f ${sshdDir}/sshd.pid ]; then
      ${pkgs.procps}/bin/ps -p "$(cat ${sshdDir}/sshd.pid)" -o pid,etime,args || true
    else
      echo "no pidfile"
    fi
    echo "== tunnel"
    if [ -f ${sshdDir}/tunnel.pid ]; then
      ${pkgs.procps}/bin/ps -p "$(cat ${sshdDir}/tunnel.pid)" -o pid,etime,args || true
    else
      echo "no pidfile"
    fi
    echo "== tunnel.log"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/tunnel.log 2>/dev/null || true
    echo "== up.log"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/up.log 2>/dev/null || true
  '';
in
{
  environment.packages = with pkgs; [
    openssh
    util-linux # flock pour phone-up
    gnugrep # pratique en session de debug
    tunnelLoop # référencés ici -> installés sur le tel
    phoneUp
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

    autostart = ''
      if [ -z "''${DRY_RUN:-}" ]; then
        for f in ${home}/.zprofile ${home}/.zshrc ${home}/.profile ${home}/.bashrc; do
          if ! grep -q nod-phone-autostart2 "$f" 2>/dev/null; then
            printf '\n# nod-phone-autostart2\nif [ -x /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up ]; then /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up >/dev/null 2>&1 || true; fi\n' >> "$f"
          fi
        done
      fi
    '';
  };
}
