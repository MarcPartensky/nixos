{ config, lib, pkgs, ... }:
# Internal CA of the tailnet (Smallstep `step`, Apache-2.0).
#
# It signs the certificates of the SHORT names served by tower's internal
# proxy (`https://mesh`, `https://photos`...). No public CA can issue
# a single-label name, hence this private authority: its root is installed
# in the trust store of each device (NixOS via
# security.pki.certificateFiles, macOS via the system keychain, Android by
# hand).
#
# Hierarchy: root (10 years, key NEVER on tower, encrypted in
# secrets/intra-ca-root.yml for anywhere+mac) -> intermediate (5 years, key on
# tower in secrets/intra-ca.yml) -> leaves (90 days, renewed by the
# intra-ca-issue timer). The leaves are written to /var/lib/traefik-certs,
# read by Traefik; a renewal restarts Traefik.
let
  cfg = config.services.intraCa;
  step = pkgs.step-cli;
  intermediateCrt = ../../../certs/intra-ca-intermediate.crt;
in
{
  options.services.intraCa = {
    enable = lib.mkEnableOption "internal CA of the tailnet and issuance of service certificates";

    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "mesh" "photos" ];
      description = ''
        Short names served by the internal proxy. Each receives a certificate
        with `SAN <name>` signed by the intermediate, and a hosts entry to
        {option}`services.intraCa.hostIp` so that the name resolves without going
        through a search domain.
      '';
    };

    hostIp = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.3";
      description = "IP of the internal proxy (tower) that the short names point to.";
    };

    validFor = lib.mkOption {
      type = lib.types.str;
      default = "2160h";
      description = "Lifetime of the service certificates (90 days).";
    };

    renewBefore = lib.mkOption {
      type = lib.types.str;
      default = "720h";
      description = "Renew when less than this duration remains (30 days).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Key of the intermediate: the only secret material tower needs.
    sops.secrets."intra-ca/intermediate_key" = {
      sopsFile = ../../../secrets/intra-ca.yml;
      key = "intermediate_key";
      mode = "0400";
    };

    # Deterministic resolution of the short names, without depending on a search domain.
    networking.extraHosts = lib.concatMapStrings (n: "${cfg.hostIp} ${n}\n") cfg.names;

    # Issues or renews the leaves. Runs BEFORE traefik so that the first
    # start already has its certificates, and restarts traefik if one changed.
    systemd.services.intra-ca-issue = {
      description = "Service certificates signed by the internal CA of the tailnet";
      wantedBy = [ "multi-user.target" ];
      # AFTER traefik, never before: the script restarts traefik when a
      # certificate changes, and a `Before=traefik` on the same service creates a
      # circular wait (the restart waits for a start itself ordered
      # after this service). Verified on 15/11: unit blocked 44 min, traefik
      # stopped. On the very first boot, traefik therefore starts without a certificate and
      # the service restarts it just after; afterwards the leaves persist
      # in /var/lib/traefik-certs and there is no more outage.
      after = [ "traefik.service" ];
      wants = [ "traefik.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "traefik-certs";
        StateDirectoryMode = "0750";
      };
      script = ''
        set -eu
        changed=0
        # Traefik runs as user `traefik`: without the group on the
        # FOLDER, it cannot traverse /var/lib/traefik-certs and loads its
        # default certificate (seen at the first deployment).
        if [ "$(stat -c %G /var/lib/traefik-certs)" != "traefik" ]; then
          chgrp traefik /var/lib/traefik-certs
          chmod 0750 /var/lib/traefik-certs
          changed=1
        fi
        for name in ${lib.escapeShellArgs cfg.names}; do
          crt="/var/lib/traefik-certs/$name.crt"
          key="/var/lib/traefik-certs/$name.key"
          if [ -s "$crt" ] && [ -s "$key" ] \
             && [ "$(grep -c 'BEGIN CERTIFICATE' "$crt")" -ge 2 ] \
             && ! ${step}/bin/step certificate needs-renewal "$crt" --expires-in ${cfg.renewBefore} >/dev/null 2>&1; then
            : # already valid and complete
          else
            rm -f "$crt" "$key"
            ${step}/bin/step certificate create "$name" "$crt" "$key" \
              --profile leaf \
              --not-after ${cfg.validFor} \
              --ca ${intermediateCrt} \
              --ca-key ${config.sops.secrets."intra-ca/intermediate_key".path} \
              --san "$name" \
              --no-password --insecure --subtle --force
            # Traefik sends ONLY the content of certFile: without the intermediate
            # joined, a client cannot build the chain even by owning
            # the root ("unable to get local issuer certificate").
            cat "$crt" ${intermediateCrt} > "$crt.chain"
            mv "$crt.chain" "$crt"
            changed=1
          fi
          # Rights applied on EVERY pass, not only at creation:
          # a leaf left as root:root 0600 by a previous run
          # causes "permission denied" on the traefik side, which then serves its
          # default certificate (experienced on 16/11 on mesh.crt).
          before="$(stat -c '%G:%a' "$crt" 2>/dev/null || echo absent)"
          chgrp traefik "$crt" "$key" 2>/dev/null || true
          chmod 0640 "$crt" "$key" 2>/dev/null || true
          after="$(stat -c '%G:%a' "$crt" 2>/dev/null || echo absent)"
          [ "$before" = "$after" ] || changed=1
        done
        if [ "$changed" = 1 ] && systemctl is-active --quiet traefik; then
          systemctl restart traefik
        fi
      '';
    };

    systemd.timers.intra-ca-issue = {
      description = "Daily renewal of the internal CA certificates";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # System trust: the root is installed by
    # modules/nixos/intra-ca-trust.nix, imported by each machine's profile
    # (profiles/common for tower, deck and laptop).
  };
}
