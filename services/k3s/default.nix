{
  lib,
  pkgs,
  ...
}: {
  # Test de k8s sur tower : k3s 1 noeud, addons coupes au minimum, dans le but
  # de mesurer le cout CPU/RAM d'un plan de controle sur cette machine
  # (62 Go dont ~13 Go dispo, swap deja charge, 110 services systemd).
  #
  # Perimetre volontairement reduit :
  #   - garde coredns (DNS interne) + flannel (vxlan) + kube-proxy, rien d'autre
  #   - traefik, servicelb, local-storage et metrics-server desactives
  #   - aucun workload/manifeste : le noeud doit rester vide
  #   - kubeconfig en 0644 pour que l'agent puisse mesurer sans sudo
  #     (a remettre en 0600 ou a supprimer avec le module)
  #   - MemoryMax 3 Go : garde-fou, tres au-dessus du cout attendu (~0,6 Go),
  #     pour ne jamais pousser la machine dans le swap si un pull d'image part
  #     en vrille. Pas de MemoryHigh : on mesure sans throttler.
  #   - CPUWeight 50 et Nice 10 : k3s passe apres le desktop de marc.
  #
  # Desactivation complete : retirer l'import de services/k3s dans
  # profiles/tower/configuration.nix, rebuild, puis supprimer /var/lib/rancher/k3s
  # (et /etc/rancher/k3s) pour rendre le disque.
  #
  # Debug : mesurer sans sudo via `kubectl` (kubeconfig deja copie par le
  # module a /etc/rancher/k3s/k3s.yaml). Cout : lire
  # /sys/fs/cgroup/system.slice/k3s.service/memory.current et
  # /sys/fs/cgroup/system.slice/k3s.service/cpu.stat.

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--disable=traefik"
      "--disable=servicelb"
      "--disable=local-storage"
      "--disable=metrics-server"
      "--write-kubeconfig-mode=0644"
    ];
  };

  # Le pare-feu nftables de NixOS coupe le trafic entrant sur les interfaces du
  # CNI : sans ca, coredns et les pods ne recoivent rien. Utile seulement pour
  # les tests de charge (P2), mais on le declare des le depart.
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" ];

  # kubectl pour les mesures (l'agent n'a pas le home-manager de marc).
  environment.systemPackages = [ pkgs.kubectl ];

  systemd.services.k3s.serviceConfig = {
    Nice = 10;
    CPUWeight = 50;
    MemoryMax = "3G";
  };
}
