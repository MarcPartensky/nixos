# Garde runtime de wg0 (tunnel Pangolin, clients newt), rejouee toutes les
# 5 minutes en plus des hooks de demarrage.
#
# Complement de gerbil-wg0-ensure.nix (qui ne couvre que le demarrage de
# gerbil) : ici on repare a chaud ce qu'un reboot, un switch ou un restart de
# service peut casser au fil de l'eau.
#
# 1. Adresse de wg0 : dhcpcd a retire 100.89.128.1/24 le 2026-10-23 (rescan de
#    carrier apres le restart de dbus-broker/traefik), laissant le tunnel avec
#    des poignees de main WireGuard valides mais zero octet de donnees.
# 2. Exception pare-feu : tailscaled droppe, via sa chaine ts-input, tout
#    paquet source 100.64.0.0/10 recu sur une interface autre que tailscale0.
#    wg0 EST dans cette plage (100.89.128.0/24) : sans ACCEPT en tete d'INPUT,
#    les SYN-ACK et ICMP de tower sont jetes cote VPS (poignees de main OK,
#    Traefik en 504 partout, 6h40 de panne le 2026-10-23).
#
# Note : meme logique que /usr/local/bin/wg0-guard.sh + wg0-guard.{service,timer}
# poses en imperatif sur le VPS le soir de la panne. Quand ce module sera
# deploye, retirer l'installation imperative :
#   systemctl disable --now wg0-guard.timer && rm /etc/systemd/system/wg0-guard.* /usr/local/bin/wg0-guard.sh
{ pkgs, lib, ... }:
{
  systemd.services.wg0-runtime-guard = {
    description = "Repare la garde runtime de wg0 (adresse + exception pare-feu tailscale)";
    after = [ "network-online.target" "tailscaled.service" "firewall.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "wg0-runtime-guard";
        runtimeInputs = [ pkgs.coreutils pkgs.iproute2 pkgs.iptables pkgs.gnugrep ];
        text = ''
          if ip link show wg0 >/dev/null 2>&1; then
            if ! ip -4 addr show wg0 | grep -q 'inet 100\.89\.128\.1/'; then
              echo "wg0-runtime-guard: adresse manquante, ajout 100.89.128.1/24" >&2
              ip addr add 100.89.128.1/24 dev wg0 || echo "wg0-runtime-guard: echec addr add, on continue vers la suite" >&2
            fi
            if ! ip route show dev wg0 | grep -q '100\.89\.128\.0/24'; then
              echo "wg0-runtime-guard: route manquante, ajout 100.89.128.0/24" >&2
              ip route add 100.89.128.0/24 dev wg0 || echo "wg0-runtime-guard: echec route add, on continue vers la suite" >&2
            fi
          fi
          if ! iptables -C INPUT -i wg0 -s 100.89.128.0/24 -j ACCEPT 2>/dev/null; then
            echo "wg0-runtime-guard: exception pare-feu absente, insertion" >&2
            iptables -I INPUT 1 -i wg0 -s 100.89.128.0/24 -j ACCEPT || echo "wg0-runtime-guard: echec insertion de la regle" >&2
          fi
        '';
      });
    };
  };

  systemd.timers.wg0-runtime-guard = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };
}
