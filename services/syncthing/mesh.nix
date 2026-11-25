# Syncthing node and folder registry for marc's fleet.
#
# Each node is identified by its Syncthing ID (fingerprint of its TLS
# certificate, stable as long as the certificate is not regenerated) and by its
# address in the headscale mesh (100.64.0.0/10, see services/tailscale).
#
# No third-party server is used: global discovery, public relays, STUN
# and telemetry are disabled in settings.nix. Nodes join through
# these fixed addresses and, on the same LAN, through local discovery.
#
# Add or remove a node: edit `nodes`, then re-activate ALL the nodes.
# Pairing is mutual: a device only connects if both sides
# declare it. `id = null` = node declared but not yet paired (ignored by the
# others, which avoids blocking a deployment before its first activation).
{
  nodes = {
    tower = {
      id = "6YG3PDA-FTD7V3X-FLH65Y3-DSTEQFP-3XBDT4Y-KGYTA3S-WC3PZEL-6Z7FZAU";
      addresses = ["tcp://100.64.0.3:22000"];
    };

    laptop = {
      # Local certificate name: "nixos" (laptop hostname); renamed
      # "laptop" here for the fleet.
      id = "LW4PLNZ-UYPPYQB-TAQL4SB-YEHX2UC-ILNADW6-QNBANZE-AELBWIF-5ITP4AO";
      addresses = ["tcp://100.64.0.4:22000"];
    };

    deck = {
      id = "QTKE6RT-GEQ4WTW-3KFZVLF-NERKAC4-KUHO7CE-2IGI6DS-P7DFXU5-FYOJLQ3";
      addresses = ["tcp://100.64.0.2:22000"];
    };

    mac = {
      id = "JSTDKMJ-MAO5RCY-RX6R5UP-EFTW74F-TYC54OM-Z5LTHIM-KBSPNME-H4Z35AI";
      # Not yet a member of the headscale mesh (Tailscale.app to install): on the
      # LAN in the meantime. Add "tcp://100.64.0.x:22000" when it is there.
      addresses = ["tcp://192.168.1.48:22000"];
    };

    # phone = {
    #   id = "";
    #   addresses = ["tcp://100.64.0.5:22000"];
    #   hostNames = ["nix-on-droid"];
    # };
  };

  # Shared folders. Rules:
  #  - `members`: who owns a copy. A node absent from the list does not
  #    declare the folder at all, so no empty tree.
  #  - path per OS; `macPath = null` forbids the folder on the Mac.
  #  - uniform type sendreceive: the three Linux share the same
  #    homeConfiguration, so nothing would allow making tower a
  #    sendonly. Deletions can be recovered via 30-day versioning.
  folders = [
    {
      # marc's Documents: the Mac is the only one with the populated version
      # (2.1 GB); tower, the laptop and the deck start from scratch. sendreceive
      # everywhere: it is a working folder, not a mirror.
      id = "personal";
      label = "Marc Partensky";
      linuxPath = "/home/marc/Personal";
      macPath = "/Users/marc/Syncthing/Marc Partensky";
      members = ["tower" "laptop" "deck" "mac"];
    }
    {
      # Photos: tower is authoritative (adb + phone Syncthing), the laptop and
      # the deck keep a copy in receiveonly. The Mac is excluded: 42 GB
      # free for 60 GB of photos.
      id = "photos-camera";
      label = "Photos camera";
      linuxPath = "/home/marc/media/photos/camera";
      macPath = null;
      members = ["tower" "laptop" "deck"];
    }
    {
      id = "photos-whatsapp";
      label = "Photos WhatsApp";
      linuxPath = "/home/marc/media/photos/whatsapp";
      macPath = null;
      members = ["tower" "laptop" "deck"];
    }
  ];
}
