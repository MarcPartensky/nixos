# Garantit que wg0, l'interface qui porte les clients newt, a bien son adresse
# à chaque démarrage de gerbil.
#
# Pourquoi : gerbil n'applique l'adresse de wg0 que s'il crée l'interface
# lui-même. Si une wg0 résiduelle existe au moment de son démarrage, il la
# réutilise telle quelle (log "WireGuard interface wg0 already exists") et
# l'interface reste sans adresse, donc sans route pour le sous-réseau des
# clients newt (100.89.128.0/24). Les poignées de main WireGuard continuent de
# passer, elles ne dépendent pas de l'adressage, mais plus aucun octet de
# données ne circule : Traefik n'atteint plus aucune cible (504 sur tous les
# domaines servis par le tunnel) et newt déclare la connexion morte toutes les
# ~3 minutes.
#
# Le workaround amont de nixpkgs (ExecStartPost de gerbil, script
# gerbil-wg0-fix-script) fait exactement ce nettoyage, mais une seule fois par
# machine : il est gardé par le marqueur /var/lib/pangolin/config/wg0, présent
# depuis avril, donc inerte depuis. Ici le contrôle est rejoué à chaque
# démarrage, sans marqueur ni redémarrage de l'unité.
{ pkgs, lib, ... }: {
  systemd.services.gerbil.serviceConfig.ExecStartPre = lib.mkForce (lib.getExe (pkgs.writeShellApplication {
    name = "gerbil-wg0-drop-unaddressed";
    runtimeInputs = [ pkgs.coreutils pkgs.iproute2 ];
    text = ''
      if ip link show wg0 >/dev/null 2>&1 && ! ip -4 addr show wg0 | grep -q 'inet '; then
        echo "wg0 présente sans adresse : suppression avant le démarrage de gerbil" >&2
        ip link delete wg0
      fi
    '';
  }));
}
