# Registre des nœuds Syncthing de la flotte de marc.
#
# Chaque nœud est identifié par son ID Syncthing (empreinte de son certificat
# TLS, stable tant que le certificat n'est pas régénéré) et par son adresse
# dans le mesh headscale (100.64.0.0/10, voir services/tailscale).
#
# Aucun serveur tiers n'est utilisé : découverte globale, relais publics, STUN
# et télémétrie sont désactivés dans settings.nix. Les nœuds se joignent par
# ces adresses fixes et, sur le même LAN, par la découverte locale.
#
# Ajouter ou retirer un nœud : éditer `nodes`, puis ré-activer TOUS les nœuds.
# Le couplage est mutuel : un appareil ne se connecte que si les deux côtés le
# déclarent. `id = null` = nœud déclaré mais pas encore appairé (ignoré par les
# autres, ce qui évite de bloquer un déploiement avant sa première activation).
{
  # Dossier partagé, même id et même contenu partout.
  folder = {
    id = "personal";
    label = "Personal";
    linuxPath = "/home/marc/Personal";
    macPath = "/Users/marc/Personal";
  };

  nodes = {
    tower = {
      id = "6YG3PDA-FTD7V3X-FLH65Y3-DSTEQFP-3XBDT4Y-KGYTA3S-WC3PZEL-6Z7FZAU";
      addresses = ["tcp://100.64.0.3:22000"];
    };

    laptop = {
      # Nom local du certificat : “nixos” (hostname du portable) ; renommé
      # « laptop » ici pour la flotte.
      id = "LW4PLNZ-UYPPYQB-TAQL4SB-YEHX2UC-ILNADW6-QNBANZE-AELBWIF-5ITP4AO";
      addresses = ["tcp://100.64.0.4:22000"];
    };

    deck = {
      id = "QTKE6RT-GEQ4WTW-3KFZVLF-NERKAC4-KUHO7CE-2IGI6DS-P7DFXU5-FYOJLQ3";
      addresses = ["tcp://100.64.0.2:22000"];
    };

    mac = {
      id = "JSTDKMJ-MAO5RCY-RX6R5UP-EFTW74F-TYC54OM-Z5LTHIM-KBSPNME-H4Z35AI";
      # Pas encore membre du mesh headscale (Tailscale.app à installer) : sur le
      # LAN en attendant. Ajouter "tcp://100.64.0.x:22000" quand il y sera.
      addresses = ["tcp://192.168.1.48:22000"];
    };

    # phone = {
    #   id = "";
    #   addresses = ["tcp://100.64.0.5:22000"];
    # };
  };
}
