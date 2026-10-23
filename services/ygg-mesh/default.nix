# services/ygg-mesh/default.nix
#
# Réseau privé chiffré entre les machines de marc, sans qu'aucun tiers ne
# connaisse leurs IP. Fichier IDENTIQUE sur chaque machine membre : il se
# repère via networking.hostName.
#
#   Hors LAN : Yggdrasil via Tor. Chaque machine n'est joignable qu'en .onion,
#              même tes machines entre elles ne voient pas leurs IP.
#   Même LAN : découverte multicast + lien direct à pleine vitesse (TLS sur
#              [fe80::...]:12346), prioritaire sur Tor. Bascule automatique
#              dans les deux sens, sans redécouverte.
#   Accès    : mot de passe partagé + clés publiques épinglées. Aucun lien avec
#              le réseau Yggdrasil public : seulement tes machines.
#
# Chaque machine obtient une IPv6 stable et un nom <hostname>.ygg (ex : ssh tower.ygg).
#
# Secret sops dédié, déchiffrable par les trois machines membres :
#   secrets/ygg-mesh.yml   ygg_password: <openssl rand -hex 24>
# Les clés Yggdrasil et onion sont générées sur chaque machine et n'en sortent jamais.
#
# Écarts vs le brouillon initial (adapté et testé le 23/10/2026) :
#   - nixpkgs 26.05 n'a PLUS d'option services.yggdrasil.configFile (remplacée
#     par `settings`, généré dans le store donc lisible par tous) : le mot de
#     passe ne peut pas y vivre. On garde la config rendue à chaud dans /run,
#     via un ExecStartPre qui lit le mot de passe dans un credential systemd.
#   - secret dans secrets/ygg-mesh.yml et pas common.yml : mêmes destinataires,
#     mais common.yml ne s'édite qu'avec la clé age privée de marc.
#   - networking.enableIPv6 forcé : les adresses ygg et le multicast ff02::114
#     sont IPv6, et modules/nixos/networking le désactive (tower, deck).
#   - Tor DÉDIÉ au mesh (ygg-mesh-tor) au lieu du tor système : le tor de tower
#     est un relais public, et tor déconseille lui-même de mélanger relais et
#     service onion dans un même processus. Surtout, le mesh ne doit pas
#     dépendre de la santé du relais : au 23/10/2026 celui de tower est coincé
#     au bootstrap (ExitNodes {ch} sans geoip, enableGeoIP = false côté
#     services/tor). Instance séparée = client + onion service uniquement,
#     SocksPort 127.0.0.1:9053.
#   - ygg-mesh-identity.service publie onion/clé/adresse dans
#     /var/lib/ygg-mesh/identity.txt (lisible sans root), pour le bootstrap.
#
# Bootstrap : voir en bas du fichier.

{ config, lib, pkgs, ... }:

let
  # ===================== A ÉDITER : les membres du réseau =====================
  # beacon = true uniquement pour les machines fixes chez toi : elles annoncent
  # leur présence sur le LAN. Les machines mobiles écoutent sans jamais s'annoncer,
  # donc restent muettes sur un wifi public.
  # onion, key et addr : à remplir après le premier rebuild. `cat
  # /var/lib/ygg-mesh/identity.txt` sur chaque machine donne les trois valeurs.
  nodes = {
    tower = {
      beacon = true;
      onion = "3oknvzva57oweu2oqqw7vyi2bluq3f3ceepgwwkgrpywpxvt2jdcnlyd.onion";
      key = "a9e47f129fe8c3b743bbfd6f2302eb5ca39202409c6deac22bdad9be38b21525";
      addr = "200:ac37:1da:c02e:7891:7888:521:b9fa";
    };
    anywhere = {
      beacon = false;
      onion = "jzrxnon4l24vyu5ndd7djkdztzo5cfot5x3j6img3mcxby6drwqcudqd.onion";
      key = "e4235bfcfa8a8dbb79fc97f79bba918e60233ff9b60a3e1a9511e39f65d255ac";
      addr = "200:37b9:4806:aea:e489:c06:d010:c88a";
    };
    deck = {
      beacon = false;
      onion = "j56zi2yaunqlsysildbld6rk3fwlbmlfehbzqkwfrm6lxxkrf6jf4lqd.onion";
      key = "c324ac2a81edf3abb54d9157518589ca8cd2affb34d41421105a167c5602d17d";
      addr = "200:79b6:a7aa:fc24:18a8:9564:dd51:5cf4";
    };
    # Clients sortants, sans onion (non dialables : ils sortent vers le mesh) :
    # remplir key + addr après leur premier démarrage (voir bootstrap en bas).
    # mac   = { beacon = false; onion = null; key = "<clé publique>"; addr = "<adresse ygg>"; };
    # phone = { beacon = false; onion = null; key = "<clé publique>"; addr = "<adresse ygg>"; };
  };
  secretsFile = ../../secrets/ygg-mesh.yml;
  # ============================================================================

  host = config.networking.hostName;
  me = nodes.${host} or (throw "ygg-mesh : '${host}' absent de la table nodes");

  listenPort = 12345; # Yggdrasil, en local seulement, exposé en .onion
  multicastPort = 12346; # liens directs sur le LAN (TCP ; seul le beacon écoute)
  torSocksPort = 9053; # SocksPort du tor dédié au mesh
  torLinks = 2; # connexions Tor parallèles par pair : un circuit qui tombe ne coupe rien
  configPath = "/run/yggdrasil/ygg-mesh.json";
  stateDir = "/var/lib/ygg-mesh"; # tor dédié + identité (sauvegarder ce dossier)

  others = lib.filterAttrs (n: v: n != host && v.onion != null && v.key != null) nodes;

  # Nœuds reconnus par leur seule clé publique, même sans onion : le Mac et
  # le téléphone sont des clients sortants (Tor ou multicast), pas dialables.
  # Ils doivent quand même être acceptés par les nœuds du mesh.
  known = lib.filterAttrs (n: v: n != host && v.key != null) nodes;

  # Un identifiant SOCKS différent par connexion = un circuit Tor distinct
  # (IsolateSOCKSAuth). priority=10 : Tor passe après le LAN (priorité 0, la
  # plus petite gagne). maxbackoff=5s : retente vite après une coupure (sinon
  # jusqu'à ~1 h).
  peerUris = lib.concatLists (lib.mapAttrsToList (name: n:
    map (i:
      "socks://${name}-${toString i}:x@127.0.0.1:${toString torSocksPort}/${n.onion}:${toString listenPort}"
      + "?key=${n.key}&password=@PW@&priority=10&maxbackoff=5s"
    ) (lib.range 1 torLinks)
  ) others);

  # Config complète, mot de passe en placeholder : rendue à chaud au démarrage
  # (ExecStartPre), donc jamais écrite dans le store.
  configTemplate = pkgs.writeText "ygg-mesh.json.in" (builtins.toJSON {
    Listen = [ "tcp://127.0.0.1:${toString listenPort}?password=@PW@" ];
    Peers = peerUris;
    MulticastInterfaces = [{
      Regex = "^(en|eth|wl).*";
      Beacon = me.beacon;
      Listen = true;
      Port = multicastPort;
      Priority = 0;
      Password = "@PW@";
    }];
    # Chemin du credential systemd posé par le module nixpkgs lui-même
    # (LoadCredential=private-key:... dans les deux versions). En 26.05 le
    # module bindait en plus la clé sur /private-key ; en 26.11 il n'y a plus
    # de bind et son propre défaut est justement ce chemin de credential.
    PrivateKeyPath = "/run/credentials/yggdrasil.service/private-key";
    IfName = "ygg";
    AllowedPublicKeys = lib.mapAttrsToList (_: n: n.key) known;
    NodeInfoPrivacy = true;
  });

  renderScript = pkgs.writeShellScript "ygg-mesh-render-config" ''
    set -eu
    pw="$(cat "$CREDENTIALS_DIRECTORY/ygg-mesh-password")"
    umask 077
    sed "s/@PW@/$pw/g" ${configTemplate} > ${configPath}
  '';

  # Tor dédié : client SOCKS + service onion du mesh. Aucun secret dedans
  # (juste des chemins et des ports), donc peut vivre dans le store.
  torrc = pkgs.writeText "ygg-mesh-torrc" ''
    DataDirectory ${stateDir}/tor
    SocksPort 127.0.0.1:${toString torSocksPort} IsolateDestAddr IsolateSOCKSAuth
    HiddenServiceDir ${stateDir}/tor/hs
    HiddenServicePort ${toString listenPort} 127.0.0.1:${toString listenPort}
    AvoidDiskWrites 1
    SafeLogging 1
  '';
in
{
  # Les adresses yggdrasil et la découverte multicast (ff02::114) sont IPv6 ;
  # sans ça ni le réseau ni le lien LAN direct ne fonctionnent. mkForce car
  # modules/nixos/networking (importé par tower et deck) pose false.
  networking.enableIPv6 = lib.mkForce true;

  sops.secrets.ygg_password.sopsFile = secretsFile;

  # ---------- Tor du mesh ----------
  # Utilisateur système dédié (pas DynamicUser : avec un StateDirectory
  # imbriqué sous un parent créé par un autre service, systemd bascule le
  # dossier sous /var/lib/private et laisse un symlink en boucle).
  users.users.ygg-mesh-tor = {
    isSystemUser = true;
    group = "ygg-mesh-tor";
  };
  users.groups.ygg-mesh-tor = { };

  # Migration : le premier essai (DynamicUser) a laissé ce symlink cassé.
  system.activationScripts.ygg-mesh-fix-state = ''
    if [ -L /var/lib/ygg-mesh/tor ] && [ ! -e /var/lib/ygg-mesh/tor ]; then
      rm -f /var/lib/ygg-mesh/tor
    fi
  '';

  systemd.services.ygg-mesh-tor = {
    description = "Tor dédié au mesh ygg (client + onion service)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      User = "ygg-mesh-tor";
      Group = "ygg-mesh-tor";
      StateDirectory = "ygg-mesh/tor";
      StateDirectoryMode = "0700";
      ExecStart = "${pkgs.tor}/bin/tor -f ${torrc}";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "on-failure";
      RestartSec = 15;
      # Durcissement : tor n'a besoin que du réseau et de son dossier d'état.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      CapabilityBoundingSet = [ "" ];
    };
  };

  # ---------- Yggdrasil ----------
  # On garde le module nixpkgs (clé persistée, durcissement, credential de la
  # clé privée) mais sa config générée dans le store ne peut pas porter le mot
  # de passe : le script est remplacé par le nôtre, qui lit la config rendue à
  # chaud dans /run.
  services.yggdrasil = {
    enable = true;
    persistentKeys = true; # clé générée une fois, gardée dans /var/lib/yggdrasil
    openMulticastPort = true; # UDP 9001 : les balises LAN (ff02::114:9001)
    denyDhcpcdInterfaces = [ "ygg" ];
  };

  # AUCUNE dépendance vers ygg-mesh-tor, volontairement. Le module nixpkgs pose
  # `before = [ "network.target" ]` sur yggdrasil (il fournit l'interface ygg au
  # reste du système) : tout ce dont yggdrasil dépend doit donc pouvoir démarrer
  # AVANT network.target, ce que tor ne peut pas (il lui faut le réseau). Avec
  # `after = [ "ygg-mesh-tor.service" ]` ici et ygg-mesh-tor `after =
  # [ "network.target" ]`, systemd trouvait un cycle d'ordre et supprimait
  # carrément le job yggdrasil.service/start au boot (vu au boot du 23/10/2026 :
  # « Found ordering cycle ... Job yggdrasil.service/start deleted to break
  # ordering cycle ») -> yggdrasil jamais démarré, ygg-mesh-identity en échec.
  # Sans l'ordre : yggdrasil démarre seul, retente ses pairs socks:// toutes les
  # maxbackoff=5 s tant que tor n'est pas là, et le lien LAN (multicast) ne
  # dépend pas de tor du tout.
  systemd.services.yggdrasil = {
    # Pas de limite de démarrage : au premier boot, le credential sops peut
    # arriver après yggdrasil (setupSecrets) ; Restart=always réessaie alors
    # indéfiniment au lieu de finir en start-limit-hit.
    startLimitIntervalSec = 0;
    serviceConfig = {
      LoadCredential = [ "ygg-mesh-password:${config.sops.secrets.ygg_password.path}" ];
      ExecStartPre = renderScript;
    };
    script = lib.mkForce "exec ${config.services.yggdrasil.package}/bin/yggdrasil -useconffile ${configPath}";
  };

  networking.firewall = {
    trustedInterfaces = [ "ygg" ]; # n'y circulent que tes machines
    # Seules les machines qui s'annoncent reçoivent des connexions LAN entrantes
    allowedTCPPorts = lib.optional me.beacon multicastPort;
  };

  # Noms <machine>.ygg
  networking.hosts = lib.mapAttrs' (name: n: lib.nameValuePair n.addr [ "${name}.ygg" ])
    (lib.filterAttrs (_: n: n.addr != null) nodes);

  # ---------- Identité (bootstrap sans root) ----------
  # onion + clé publique + adresse dans un fichier lisible par tous : les trois
  # valeurs à recopier dans la table `nodes` ci-dessus. Rien de secret dedans.
  systemd.services.ygg-mesh-identity = {
    description = "Identité ygg-mesh (onion, clé publique, adresse IPv6)";
    wantedBy = [ "multi-user.target" ];
    after = [ "yggdrasil.service" "ygg-mesh-tor.service" ];
    # Se relance quand tor (onion) ou yggdrasil (clé, adresse) redémarre,
    # pour recapturer une identité fraîche.
    partOf = [ "ygg-mesh-tor.service" "yggdrasil.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "ygg-mesh";
    };
    path = [ config.services.yggdrasil.package pkgs.coreutils pkgs.gnugrep ];
    script = ''
      set -eu
      onion=""
      for _ in $(seq 1 90); do
        if [ -s ${stateDir}/tor/hs/hostname ]; then
          onion="$(cat ${stateDir}/tor/hs/hostname)"
          break
        fi
        sleep 2
      done
      self=""
      for _ in $(seq 1 60); do
        out="$(yggdrasilctl -json getself 2>/dev/null || true)"
        if printf '%s' "$out" | grep -q '"address"'; then
          self="$out"
          break
        fi
        sleep 2
      done
      # Fichier écrit seulement si l'identité est complète : sa présence
      # signifie « onion + clé + adresse valides ».
      rm -f ${stateDir}/identity.txt
      if [ -z "$onion" ] || [ -z "$self" ]; then
        echo "ygg-mesh-identity: incomplet (onion='$onion') — yggdrasil/tor pas prêts" >&2
        exit 1
      fi
      {
        printf 'onion=%s\n' "$onion"
        printf '%s\n' "$self"
      } > ${stateDir}/identity.txt
      chmod 0644 ${stateDir}/identity.txt
    '';
  };
}

# ================================ BOOTSTRAP ================================
#
# 1. Mot de passe commun : déjà posé (secrets/ygg-mesh.yml, chiffré pour
#    anywhere/tower/deck/deck-host). Rotation : réécrire le clair puis
#    `nix run nixpkgs#sops -- -e --filename-override secrets/ygg-mesh.yml
#      --output secrets/ygg-mesh.yml <clair>`, et rebuild partout.
#
# 2. Importer ce fichier sur chaque machine (onion, key, addr = null), rebuild.
#
# 3. Sur CHAQUE machine, `cat /var/lib/ygg-mesh/identity.txt` donne :
#      onion=...        -> champ onion (sans le .onion final)
#      "key": "..."     -> champ key
#      "address": ...   -> champ addr
#
# 4. Remplir la table, rebuild partout.
#
# Vérifier :
#      ping tower.ygg                  # depuis n'importe quelle machine du mesh
#      sudo yggdrasilctl getpeers      # liens socks:// (Tor) et tls://[fe80::...] (LAN)
#      journalctl -u ygg-mesh-tor      # bootstrap tor + publication de l'onion
#
# Réinstallation d'une machine : sauvegarder /var/lib/yggdrasil/private.pem et
# /var/lib/ygg-mesh/tor (tor/hs = identité onion) pour garder la même identité,
# sinon refaire l'étape 3 pour cette machine.
