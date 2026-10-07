{
  lib,
  pkgs,
  inputs,
  config,
  ...
}: let
  # Client WireGuard vers le VPS (voir la section WIREGUARD CLIENT en bas).
  wgClientEnable = false;
in {
  imports = [
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
    ../../modules/nixos/herdr
  ];

  # Sessions hermes lancees par marc (panes herdr, HERMES_HOME partage, cf
  # users/marc/home.nix) : elles ecrivent dans /var/lib/hermes/.hermes. Le
  # groupe hermes (users.nix) plus les chmod g+rw du module hermes couvrent
  # l'existant ; ces ACL garantissent la traversee de /var/lib/hermes (2770) et
  # que les fichiers crees par marc restent lisibles par le service.
  # Pattern repris de services/firefox-mcp et amazon-mcp.
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "a /var/lib/hermes/.hermes - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
    "a /var/lib/hermes/.hermes/plugins - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
  ];

  boot.kernelParams = ["panic=10"];
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  boot.kernelModules = ["vkms"];
  boot.initrd.secrets."/etc/secrets/zfs-root.key" = "/etc/secrets/zfs-root.key";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      2022
      8083 # Pangolin / Apps
      8050
      5432 # PostgreSQL
      6080 # noVNC (client VNC web de la session niri)
      8089 # rustguac
      8443 # KasmVNC
      8200 # Vault
      21115 21116 21118 # RustDesk
      8080 # Dioxus dev (winnie UI)
    ];
  };

  users.users.hermes.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
  ];

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;

  nixpkgs.overlays = [ inputs.ankimcp.overlays.default ];

  # ACME/Let's Encrypt : PLUS UTILISE sur tower. Le DNS public
  # (*.marcpartensky.com) est un wildcard vers le VPS 104.129.12.158 (Pangolin),
  # donc un challenge http-01 ne peut jamais atteindre tower (derriere NAT) :
  # chaque vhost ACME finissait en « order-renew ... failed », et un contact
  # admin@example.com est de toute facon refuse par Let's Encrypt
  # (« contact email has forbidden domain example.com »).
  # Les vhosts nginx locaux ci-dessous sont donc en HTTP loopback, destines a etre
  # exposes par une ressource Pangolin/newt qui porte, elle, le TLS.
  # Si un jour l'ACME revient ici : security.acme.defaults.email = "<vrai email>";
  # (l'ancienne option security.acme.email est depreciee) + acceptTerms = true.

  services.hermes.enableMatrixToken = true;
  services.hermes.enableDiscordToken = true;

  # ========================================================================
  # RUSTGUAC - Gateway Rust (remplace Guacamole Java)
  # ========================================================================
  services.rustguac = {
    enable = true;
    host = "127.0.0.1";
    port = 8089;
    # guacd n'a pas de TLS ici : il ecoute en loopback, et rustguac doit parler
    # le meme protocole que lui (tls = true des deux cotes, ou false des deux
    # cotes, sinon la connexion guacamole ne s'etablit pas).
    guacd = { host = "127.0.0.1"; port = 4822; tls = false; };
    vault = {
      address = "http://127.0.0.1:8200";
      rootTokenFile = "/run/secrets/vault-rustguac-root-token";
      mountPath = "secret";
      basePath = "rustguac";
    };
    # OIDC DESACTIVE (29/09/2026) : rustguac 1.10.0 attend redirect_uri (pas
    # redirect_url), default_role, extra_scopes, et un client_secret LITTERAL ou
    # la variable OIDC_CLIENT_SECRET (pas un chemin de fichier). Surtout, il faut
    # d'abord creer l'app OIDC dans Zitadel : client "rustguac", redirect
    # https://guac.marcpartensky.com/auth/callback, puis exposer le vhost via une
    # ressource Pangolin. Pour l'activer :
    #   oidc = { issuerUrl = "https://auth.marcpartensky.com"; clientId = "rustguac";
    #            clientSecretFile = "/run/secrets/rustguac-oidc-client-secret";
    #            redirectUri = "https://guac.marcpartensky.com/auth/callback";
    #            defaultRole = "operator"; extraScopes = [ "groups" ]; };
    # En attendant, l'auth est par cle API (`rustguac add-admin`).
    oidc = null;
    recording = {
      enable = true;
      path = "/var/lib/rustguac/recordings";
      maxDiskPercent = 80;
    };
    # Pas de rate limiting ici : nginx est devant, et rustguac le recommande
    # desactive derriere un reverse proxy.
    rateLimit = false;
    trustedProxies = [ "127.0.0.1/32" ];
  };

  # ========================================================================
  # KASMVNC - Bureau personnel Wayland haute perf (LXQt + kwin_wayland)
  # ========================================================================
  services.kasmvnc = {
    enable = true;
    user = "marc";
    # :1 est DEJA pris par la session graphique de marc (Xwayland :1) :
    # kasmvncserver refuse alors de demarrer (« tower:1 is taken because of
    # /tmp/.X1-lock ») et l'unite boucle jusqu'au start-limit-hit.
    display = ":20";
    geometry = "1920x1080";
    port = 8443;
    tls = {
      certFile = "/run/secrets/kasmvnc-cert-pem";
      keyFile = "/run/secrets/kasmvnc-key-pem";
    };
    passwordFile = "/home/marc/.kasmpasswd";
    desktop = "lxqt";
  };

  # /home/marc/.kasmpasswd : fichier au format kasmvncpasswd. Attention,
  # kasmvncpasswd n'a PAS d'option -f et refuse de tourner sans terminal
  # (« getpassword error: Inappropriate ioctl for device ») ; il lit le mot de
  # passe sur stdin quand on le lui donne deux fois. L'activation tourne donc en
  # root, cree le fichier une fois, puis le passe a marc. Le mot de passe vit
  # dans secrets/kasmvnc.yml (`sops -d secrets/kasmvnc.yml` pour le lire).
  # -w -o (write + owner) donnent a marc une session utilisable : sans champ de
  # permission kasmvncserver annonce « Users configured: marc (can only view) »,
  # soit une session en lecture seule. (Mesure : l'authentification HTTP passe
  # quand meme sans ces flags, 200 avec le bon mot de passe et 401 avec un
  # mauvais ; un 401 sur un mot de passe correct signifie que l'utilisateur
  # n'existe pas dans le fichier, pas que les flags manquent.)
  # La regeneration est pilotee par une empreinte du secret : le fichier n'est
  # reecrit que si le mot de passe a change, sinon chaque switch relancerait la
  # session en cours pour rien (kasmvncserver ne lit ce fichier qu'au demarrage,
  # donc un changement de secret impose un restart). Le test de fumee final ne
  # journalise QUE le code HTTP, jamais le mot de passe.
  system.activationScripts.kasmvncPasswd = ''
    if [ -r /run/secrets/kasmvnc-password ]; then
      pw="$(cat /run/secrets/kasmvnc-password)"
      want="$(printf %s "$pw" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      have="$(cat /var/lib/kasmvnc/password.sha256 2>/dev/null || true)"
      if [ "$want" != "$have" ]; then
        printf '%s\n%s\n' "$pw" "$pw" | ${config.services.kasmvnc.package}/bin/kasmvncpasswd -u marc -w -o /home/marc/.kasmpasswd || true
        chmod 600 /home/marc/.kasmpasswd 2>/dev/null || true
        chown marc:users /home/marc/.kasmpasswd 2>/dev/null || true
        install -d -m 0755 /var/lib/kasmvnc
        printf '%s' "$want" > /var/lib/kasmvnc/password.sha256
        ${pkgs.systemd}/bin/systemctl --user -M marc@.host reset-failed kasmvnc.service 2>/dev/null || true
        ${pkgs.systemd}/bin/systemctl --user -M marc@.host restart kasmvnc.service 2>/dev/null || true
        code="000"
        for i in 1 2 3 4 5 6 7 8 9 10; do
          code="$(${pkgs.curl}/bin/curl -sk -o /dev/null -w '%{http_code}' -u "marc:$pw" https://127.0.0.1:8443/ 2>/dev/null || true)"
          if [ "$code" = "200" ]; then break; fi
          sleep 2
        done
        echo "kasmvnc: mot de passe (re)genere, authentification locale -> HTTP $code" >&2
      fi
      unset pw want have
    fi
  '';

  # ========================================================================
  # VAULT - Dev mode pour rustguac (stockage connexions)
  # ========================================================================
  services.vault-rustguac = {
    enable = true;
    mode = "dev";
    address = "127.0.0.1";
    port = 8200;
    devRootToken = "/run/secrets/vault-rustguac-root-token";
    ui = true;
  };

  # ========================================================================
  # RUSTDESK - Serveur P2P (hbbs + hbbr)
  # ========================================================================
  # Ports reels de la 1.1.16 : hbbs 21115 (test NAT) / 21116 (ID, TCP+UDP) /
  # 21118 (websocket), hbbr 21117 (relais) / 21119 (websocket). Sans -k, hbbs
  # genere sa paire de cles dans /var/lib/rustdesk (id_ed25519*).
  # NOTE : tower est derriere NAT residentiel ; ces ports ne sont utiles qu'en
  # LAN tant que rien n'est redirige cote box (ou via le VPS).
  services.rustdesk = {
    enable = true;
    hbbs = { enable = true; idPort = 21116; };
    hbbr = { enable = true; port = 21117; };
    openFirewall = true;
  };

  # ========================================================================
  # NGINX - vhosts locaux (TLS porte par Pangolin/newt, pas par nginx ici)
  # ========================================================================
  services.nginx.rustguac = {
    enable = true;
    domain = "guac.marcpartensky.com";
    upstream = "http://127.0.0.1:8089";
    acme = false;
    listenAddress = "127.0.0.1";
    listenPort = 8289;
  };

  services.nginx.kasmvnc = {
    enable = true;
    domain = "kasm.marcpartensky.com";
    upstream = "https://127.0.0.1:8443";
    acme = false;
    listenAddress = "127.0.0.1";
    listenPort = 8288;
  };

  # Exposition publique via Pangolin (newt, site "tower") : kasm.marcpartensky.com
  # -> 127.0.0.1:8288, le vhost nginx local qui repart en https vers KasmVNC.
  # HTTP + SSO, comme noVNC (vnc.marcpartensky.com) : newt 1.12.4 suffit, le mode
  # VNC natif de Pangolin exigerait un connecteur > 1.13. Meme contrainte de
  # schema que services/newt : ce Pangolin attend `proxy-resources` + `protocol`
  # (`public-resources`/`mode` sont ignores en silence -> domaine en 404).
  # Pas de healthcheck : KasmVNC repond 401 sur / sans authentification, donc un
  # healthcheck HTTP marquerait la cible unhealthy et Pangolin la sortirait du
  # load-balancer (lecon du healthcheck noVNC dans services/newt).
  services.newt.blueprint.proxy-resources.kasm = {
    name = "kasm";
    protocol = "http";
    full-domain = "kasm.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8288;
        method = "http";
      }
    ];
  };

  # ========================================================================
  # SECRETS (sops-nix)
  # ========================================================================
  sops.secrets = {
    # Lu par le service vault (User=vault) : owner root + 0400 rendait le
    # fichier illisible pour lui, donc `vault server -dev` sortait en EACCES.
    vault-rustguac-root-token = {
      sopsFile = ../../secrets/tower.yml;
      owner = "vault";
      mode = "0400";
    };
    # Lu par le service rustguac lui-meme (User=rustguac).
    rustguac-oidc-client-secret = {
      sopsFile = ../../secrets/tower.yml;
      owner = "rustguac";
      mode = "0400";
    };
    kasmvnc-cert-pem = {
      sopsFile = ../../secrets/tower.yml;
      owner = "marc";
      mode = "0400";
    };
    kasmvnc-key-pem = {
      sopsFile = ../../secrets/tower.yml;
      owner = "marc";
      mode = "0400";
    };
    # Mot de passe KasmVNC (web login), lu par le script d'activation cote root.
    kasmvnc-password = {
      sopsFile = ../../secrets/kasmvnc.yml;
      owner = "root";
      mode = "0400";
    };
    # "pangolin/api_key" : volontairement absent, la cle n'existe pas dans
    # secrets/common.yml (la declarer fait echouer tout le switch en
    # « the key 'pangolin' cannot be found »). Voir services/hermes/default.nix.
  };

  # User lingering pour KasmVNC systemd user service
  users.users.marc.linger = true;

  # hermes doit pouvoir lire les journaux (y compris les unites utilisateur de
  # marc, ex. kasmvnc) : sans ca, aucun diagnostic possible sans root, et sudo
  # n'est autorise que pour nixos-rebuild.
  users.users.hermes.extraGroups = [ "systemd-journal" ];

  # ========================================================================
  # WIREGUARD CLIENT - Connexion au réseau VPN du VPS RackNerd (anywhere)
  # ========================================================================
  # Objectif : tower rejoint le réseau wireguard (10.100.0.0/24) du VPS
  # pour que macOS (et d'autres pairs) puisse s'y connecter directement
  # via SSH dans le VPN (alias tower-rack), sans rediriger le trafic
  # internet de tower via le serveur VPN.
  #
  # MANQUE AVANT ACTIVATION :
  # 1. Générer la paire de clés de tower : `wg genkey | tee privatekey | wg pubkey > publickey`
  # 2. Insérer le secret dans secrets/tower.yml (sops) :
  #    wireguard:
  #      tower_private_key: ENC[AES256_GCM,...]
  # 3. Déclarer le secret dans la conf (déjà fait ci-dessous, conditionnel)
  #
  # Le peer (serveur anywhere) : publicKey = la clé publique du VPS
  # (extraite du service wireguard de anywhere, ou via `wg showconf wg1` sur le VPS).
  # Endpoint : le VPS RackNerd expose wireguard sur le port 443 UDP.
  # IP attribuée au client tower : 10.100.0.3/32 (cohérente avec le réseau existant).
  #
  # ATTENTION : `allowedIPs = [ "10.100.0.0/24" ];` limite le tunnel au réseau
  # privé du VPN ; le trafic internet de tower ne passe PAS par le VPS.
  # ========================================================================
  # DESACTIVE tant que le secret n'existe pas : sops-nix refuse de construire le
  # manifeste si la cle est absente de tower.yml (« the key 'wireguard' cannot be
  # found »), ce qui casse tout le build. Passer a true apres les etapes 1 et 2
  # ci-dessus (et l'ajout de la cle publique de tower comme peer sur le VPS).
  networking.wg-quick.interfaces = lib.mkIf wgClientEnable {
    wg1 = {
      address = [ "10.100.0.3/32" ];
      # Clé privée du client tower. Créer le secret sops avant d'activer.
      # Le chemin est résolu par sops-nix depuis secrets/tower.yml.
      privateKeyFile = config.sops.secrets."wireguard/tower_private_key".path;
      peers = [
        {
          # Clé publique du serveur wireguard du VPS (anywhere / RackNerd)
          publicKey = "dsOBj2AfqF7YQ1JTGfYjlFse5sFZzwudOBiEMDLAzhU=";
          endpoint = "104.129.12.158:443";
          # Seul le réseau privé du VPN est routé via le tunnel ;
          # le trafic internet de tower reste sur la connexion locale.
          allowedIPs = [ "10.100.0.0/24" ];
          persistentKeepalive = 25;
        }
      ];
    };
  };

  # Secret sops nécessaire pour le client wireguard (à créer dans secrets/tower.yml)
  sops.secrets."wireguard/tower_private_key" = lib.mkIf wgClientEnable {
    sopsFile = ../../secrets/tower.yml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  networking.firewall.allowedUDPPorts = lib.mkIf wgClientEnable [ 443 ];

  # ========================================================================
}