# Cache binaire Nix locale : atticd (serveur) avec stockage SUR DISQUE, et
# push automatique de chaque build via le post-build-hook du démon Nix.
#
# Le stockage est local (`type = "local"`, dossier /var/lib/atticd/storage) :
# un cache binaire mono-machine n'a pas besoin d'un moteur S3. Le backend S3
# vers rustfs a été retiré le 2026-11-11 : rustfs passait ~1 coeur en rafales de
# walk_dir au repos (mesuré à l'atop) pour un cache que seul tower lit.
#
# Objectif : ne plus recompiler les paquets maison (kasmvnc, *-mcp, hermes…)
# après un GC, un rollback ou un `nix flake update`, et servir de substituter
# aux autres machines du mesh le jour où on l'expose. Les pushes sautent les
# chemins déjà disponibles sur cache.nixos.org (upstream cache keys), donc la
# cache ne contient que ce que seul tower produit.
#
# La clé de signature est gérée par le serveur (managed signing) : elle vit
# dans la base atticd et change si la base est recréée ; `attic cache info
# nixos` l'affiche, et elle est épinglée dans `nix.settings.trusted-public-keys`
# (section phase 2 en bas du fichier). Un changement de clé impose de repeindre
# cette ligne ET de reparcourir ce que la vieille clé avait signé.
{ pkgs, config, lib, ... }:
let
  stateDir = "/var/lib/atticd";
  cacheName = "nixos";

  # Même contenu que le config-file vérifié par le module nixpkgs, mais
  # référençable ici pour atticadm (le module ne l'expose pas).
  serverConfig = (pkgs.formats.toml { }).generate "atticd-server.toml" config.services.atticd.settings;

  # Droits du token de bootstrap : pile ce qu'il faut (pull pour lire, push
  # pour le hook, create/configure pour le bootstrap). Pas de --destroy-cache.
  tokenClaims = "--pull '*' --push '*' --create-cache '*' --configure-cache '*' --configure-cache-retention '*'";
in
{
  services.atticd = {
    enable = true;
    # Secret JWT (signature des tokens API), généré au premier switch dans
    # /var/lib/atticd/jwt.env (root, 0600). Hors sops : hermes ne peut pas
    # créer de secrets sops ; c'est de l'état local du service, comme la DB.
    environmentFile = "${stateDir}/jwt.env";
    settings = {
      # 8484 : port dédié. 8080 est déjà pris par le dev server winnie (Vite,
      # bind wildcard) ; y binder la loopback échouait silencieusement et les
      # clients attic tombaient sur Vite (SPA/404 au lieu de l'API attic).
      listen = "127.0.0.1:8484";
      storage = {
        # Stockage local : pas de backend S3, donc pas de service en plus a
        # maintenir ni de scans d'objets. Chemin sous stateDir, le module
        # nixpkgs cree le dossier et le rattache au service.
        type = "local";
        path = "${stateDir}/storage";
      };
    };
  };

  # Un seul fichier d'env : le JWT généré plus haut. Plus de creds S3 (stockage
  # local) et donc plus de dépendance à rustfs.
  systemd.services.atticd = {
    serviceConfig.EnvironmentFile = lib.mkForce [
      "${stateDir}/jwt.env"
    ];
  };

  # Génère le secret JWT une seule fois (idempotent, survit aux switches).
  system.activationScripts.atticd-jwt = ''
    install -d -m 0700 ${stateDir}
    if [ ! -s ${stateDir}/jwt.env ]; then
      umask 077
      echo "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=$(${pkgs.openssl}/bin/openssl genrsa -traditional 4096 | ${pkgs.coreutils}/bin/base64 -w0)" > ${stateDir}/jwt.env
    fi
  '';

  # Bootstrap (idempotent, au boot et après switch) : token API, cache "nixos"
  # publique en lecture, configs client (root pour le hook, hermes et marc
  # pour l'usage manuel).
  systemd.services.atticd-bootstrap = {
    description = "Bootstrap de la cache binaire attic (token, cache, configs client)";
    after = [ "atticd.service" ];
    requires = [ "atticd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "${stateDir}/jwt.env";
    };
    path = [ pkgs.attic-client pkgs.attic-server pkgs.coreutils pkgs.curl ];
    script = ''
      set -eu
      # atticd atteint l'etat "active" AVANT d'avoir fini ses migrations et
      # d'ecouter : le bootstrap qui suit immediatement tombait en
      # « Connection refused » sur _api/v1/cache-config. Attendre la socket.
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:8484/ 2>/dev/null \
           || ${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8484/ 2>/dev/null | grep -qE '^[0-9]{3}$'; then
          break
        fi
        sleep 1
      done

      token_file=${stateDir}/token
      if [ ! -s "$token_file" ]; then
        atticadm -f ${serverConfig} make-token --sub tower --validity '10 years' \
          ${tokenClaims} > "$token_file"
        chmod 0600 "$token_file"
      fi

      mkdir -p ${stateDir}/attic /var/lib/hermes/.config/attic /home/marc/.config/attic
      chown root:root ${stateDir}/attic
      chown hermes:hermes /var/lib/hermes/.config/attic
      chown marc:users /home/marc/.config/attic

      write_config() {
        # $1 chemin, $2 user, $3 group
        printf 'default-server = "tower"\n\n[servers.tower]\nendpoint = "http://127.0.0.1:8484"\ntoken = "%s"\n' \
          "$(cat "$token_file")" > "$1"
        chmod 0600 "$1"
        chown "$2:$3" "$1"
      }
      write_config ${stateDir}/attic/config.toml root root
      write_config /var/lib/hermes/.config/attic/config.toml hermes hermes
      write_config /home/marc/.config/attic/config.toml marc users

      export XDG_CONFIG_HOME=${stateDir}
      if ! attic cache info ${cacheName} >/dev/null 2>&1; then
        attic cache create ${cacheName} --public
      fi
    '';
  };

  # Pousse chaque sortie fraîchement buildée par le démon Nix. Un échec est
  # ignoré : la cache est un accélérateur, pas une garantie de service.
  nix.settings.post-build-hook = pkgs.writeShellScript "attic-post-build-hook" ''
    set -u
    if [ -z "''${OUT_PATHS:-}" ]; then exit 0; fi
    export XDG_CONFIG_HOME=${stateDir}
    if [ -s ${stateDir}/attic/config.toml ]; then
      ${pkgs.attic-client}/bin/attic push ${cacheName} $OUT_PATHS \
        || echo "attic push a échoué (ignoré)" >&2
    fi
  '';

  environment.systemPackages = [ pkgs.attic-client ];

  # Phase 2 : substituer depuis la cache locale d'abord, puis cache.nixos.org.
  # PIEGE : `nix.settings.substituters` REMPLACE la liste par defaut de nixpkgs,
  # il ne la complete pas. Ne declarer que la cache locale ferait compiler en
  # local tout chemin amont absent de la cache. Les deux doivent figurer ici.
  # La cle publique vient de `attic cache info nixos` (managed signing) ; elle
  # change si la base atticd est recreee, donc re-verifier apres une remise a
  # zero du stateDir.
  nix.settings.substituters = [
    "http://127.0.0.1:8484/${cacheName}"
    "https://cache.nixos.org/"
  ];
  nix.settings.trusted-public-keys = [ "nixos:mGLkZ8N9hIbCeznuZ79qCTDPfoifJ3EaNAJxbNKOiYk=" ];
}
