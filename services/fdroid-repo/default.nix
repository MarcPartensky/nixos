# services/fdroid-repo/default.nix
# Dépôt F-Droid personnel de Marc : https://fdroid.marcpartensky.com
#
# Chaîne : Droidify / F-Droid (client Android)
#          -> Pangolin (fdroid.marcpartensky.com, SSO DÉSACTIVÉ)
#          -> newt (site tower)
#          -> 127.0.0.1:8093 (nginx, sert /var/lib/fdroid/repo)
#
# Pourquoi SSO désactivé : un dépôt F-Droid est lu par un client natif qui ne
# sait pas suivre une redirection de login. Il fait des GET anonymes sur
# index-v2.json, index-v1.jar et les APK. Le dépôt ne contient donc que des
# artefacts publics (des APK release signés) : aucun secret ne transite.
#
# Signature : la clé du dépôt (keystore JKS) est le SEUL secret, stocké chiffré
# dans secrets/fdroid.yml (destinataire tower) et posé dans /var/lib/fdroid par
# l'unité de publication. Si elle est perdue, les clients doivent supprimer
# puis ré-ajouter le dépôt (nouvelle empreinte) : la sauvegarde du keystore,
# c'est secrets/fdroid.yml dans le repo git.
#
# Publication : déposer un APK dans /var/lib/fdroid/incoming (boîte aux lettres
# sticky 1777, donc sans sudo ni appartenance à un groupe). Le path unit
# fdroid-repo-publish.path déclenche fdroid-repo-publish.service, qui déplace
# l'APK dans repo/, régénère les index (v1 + v2) et les signe. Journal :
# journalctl -u fdroid-repo-publish.
#
# Métadonnées par application (nom, description, catégories, captures) :
# /var/lib/fdroid/metadata/<package>.yml, éditables par marc (groupe fdroid).
# `fdroid update --create-metadata` ne crée que les squelettes manquants, donc
# un fichier existant n'est jamais écrasé.
#
# Versions gérées : un APK plus récent du même paquet s'ajoute à l'index à côté
# des précédents (Droidify propose la mise à jour), à condition d'être signé par
# la MÊME clé applicative que l'APK déjà publié (sinon Android refuse
# l'installation par-dessus).
{
  config,
  lib,
  pkgs,
  ...
}: let
  stateDir = "/var/lib/fdroid";
  repoDir = "${stateDir}/repo";
  metadataDir = "${stateDir}/metadata";
  incomingDir = "${stateDir}/incoming";
  httpPort = 8093;

  # Étape privilégiée : arborescence, config.yml (mot de passe du keystore) et
  # décodage du keystore. Tourne en root via le préfixe "+" d'ExecStartPre.
  prepare = pkgs.writeShellApplication {
    name = "fdroid-repo-prepare";
    runtimeInputs = [pkgs.coreutils pkgs.bash pkgs.findutils];
    text = ''
      set -eu

      install -d -o fdroid -g fdroid -m 0755 ${stateDir}
      install -d -o fdroid -g fdroid -m 0755 ${repoDir} ${repoDir}/icons
      install -d -o fdroid -g fdroid -m 0775 ${metadataDir}
      # Boîte aux lettres : sticky 1777 pour que marc et l'agent hermes y
      # déposent un APK sans sudo ni appartenance au groupe fdroid. Le sticky
      # bit empêche fdroid de renommer un fichier déposé par un autre
      # utilisateur : on lui en donne la propriété ici (on tourne en root).
      install -d -m 1777 ${incomingDir}
      find ${incomingDir} -maxdepth 1 -type f -name '*.apk' -exec chown fdroid:fdroid {} +

      install -o fdroid -g fdroid -m 0600 \
        ${config.sops.templates."fdroid-config.yml".path} ${stateDir}/config.yml

      if [ ! -r /run/secrets/fdroid_keystore_b64 ]; then
        echo "secret fdroid_keystore_b64 illisible" >&2
        exit 1
      fi
      tmp=$(mktemp ${stateDir}/.keystore.XXXXXX)
      base64 -d < /run/secrets/fdroid_keystore_b64 > "$tmp"
      chown fdroid:fdroid "$tmp"
      chmod 0600 "$tmp"
      mv -f "$tmp" ${stateDir}/keystore.jks

      # Icône du dépôt : fdroid la copie lui-même dans repo/icons/icon.png, donc
      # la source doit être HORS du dossier repo (sinon SameFileError).
      install -o fdroid -g fdroid -m 0644 ${./repo-icon.png} ${stateDir}/icon.png
    '';
  };

  # Étape non privilégiée : ingestion des APK + régénération/signature.
  publish = pkgs.writeShellApplication {
    name = "fdroid-repo-publish";
    runtimeInputs = [pkgs.fdroidserver pkgs.jdk pkgs.coreutils pkgs.bash pkgs.python3];
    text = ''
      set -eu
      cd ${stateDir}

      shopt -s nullglob
      apks=(incoming/*.apk)
      if [ ''${#apks[@]} -gt 0 ]; then
        for f in "''${apks[@]}"; do
          echo "ingestion : $(basename "$f")"
          mv -f "$f" ${repoDir}/
        done
      fi

      # --create-metadata : squelette de métadonnées pour tout paquet nouveau,
      # les fichiers déjà présents ne sont pas touchés.
      fdroid update --create-metadata

      # Catégorie par défaut des squelettes = nom du dossier courant ("fdroid"),
      # invalide côté F-Droid : on la remplace puis on régénère l'index.
      fixed=$(python3 ${./fix-categories.py})
      if [ -n "$fixed" ]; then
        echo "catégorie par défaut remplacée pour : $fixed"
        fdroid update
      fi

      echo "dépôt régénéré : $(ls -l ${repoDir}/index-v2.json)"
    '';
  };
in {
  users.groups.fdroid = {};
  users.users.fdroid = {
    isSystemUser = true;
    group = "fdroid";
    home = stateDir;
    description = "Dépôt F-Droid personnel";
  };
  # marc édite les métadonnées et dépose des APK sans sudo.
  users.users.marc.extraGroups = ["fdroid"];

  sops.secrets.fdroid_keystore_b64 = {
    sopsFile = ../../secrets/fdroid.yml;
    mode = "0400";
    restartUnits = ["fdroid-repo-publish.service"];
  };
  sops.secrets.fdroid_keystore_pass = {
    sopsFile = ../../secrets/fdroid.yml;
    mode = "0400";
    restartUnits = ["fdroid-repo-publish.service"];
  };

  # config.yml du dépôt : le mot de passe du keystore ne peut pas être en
  # clair dans le store nix, donc le fichier est rendu à l'activation.
  sops.templates."fdroid-config.yml" = {
    owner = "fdroid";
    group = "fdroid";
    mode = "0600";
    restartUnits = ["fdroid-repo-publish.service"];
    content = ''
      repo_url: https://fdroid.marcpartensky.com/repo
      repo_name: Marc Partensky
      repo_description: Applications Android personnelles de Marc.
      # fdroid combine repo_icon avec repo/icons/ : valeur = simple nom de
      # fichier, source = icon.png à la racine de stateDir (hors dossier repo).
      repo_icon: icon.png
      repo_keyalias: fdroid
      keystore: ${stateDir}/keystore.jks
      keystorepass: ${config.sops.placeholder.fdroid_keystore_pass}
      keypass: ${config.sops.placeholder.fdroid_keystore_pass}
    '';
  };

  # Arborescence créée au boot (avant que le service ne démarre) : le service
  # ne peut pas avoir WorkingDirectory sur un dossier qui n'existe pas encore.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 fdroid fdroid -"
    "d ${repoDir} 0755 fdroid fdroid -"
    "d ${repoDir}/icons 0755 fdroid fdroid -"
    "d ${metadataDir} 0775 fdroid fdroid -"
    "d ${incomingDir} 1777 root root -"
  ];

  systemd.services.fdroid-repo-publish = {
    description = "Régénère et signe le dépôt F-Droid personnel";
    environment = {
      HOME = stateDir;
      # fdroid écrit son cache sous $HOME/.cache ; stateDir appartient à fdroid.
      XDG_CACHE_HOME = "${stateDir}/.cache";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "fdroid";
      Group = "fdroid";
      UMask = "0022";
      ExecStartPre = "+${prepare}/bin/fdroid-repo-prepare";
      ExecStart = "${publish}/bin/fdroid-repo-publish";
      TimeoutStartSec = "900";
    };
  };

  # Déclenchement automatique dès qu'un APK apparaît dans la boîte aux lettres.
  systemd.paths.fdroid-repo-publish = {
    wantedBy = ["multi-user.target"];
    pathConfig.DirectoryNotEmpty = incomingDir;
  };

  # Vhost local en HTTP loopback : le TLS est porté par Pangolin/newt.
  # Seul /repo/ est servi (root = stateDir + uri -> stateDir/repo/...) : le
  # keystore et config.yml restent hors de portée d'une requête HTTP.
  services.nginx.virtualHosts."fdroid-repo" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = httpPort;
      }
    ];
    root = stateDir;
    locations."/repo/" = {
      tryFiles = "$uri $uri/ =404";
    };
    locations."/" = {
      return = "404";
    };
    extraConfig = ''
      autoindex off;
      # Les index et les APK sont réécrits à chaque publication : pas de cache
      # long côté proxys, sinon un client peut voir un index périmé pendant
      # des heures.
      add_header Cache-Control "public, max-age=300";
    '';
  };

  # Ressource publique (SSO désactivé, cf. en-tête) : schema ancien de ce
  # Pangolin -> `proxy-resources` + `protocol` + cible `127.0.0.1`.
  services.newt.blueprint.proxy-resources.fdroid = {
    name = "fdroid";
    protocol = "http";
    full-domain = "fdroid.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = httpPort;
        method = "http";
      }
    ];
  };
}
