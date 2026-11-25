# services/fdroid-repo/default.nix
# Marc's personal F-Droid repository: https://fdroid.marcpartensky.com
#
# Chain: Droidify / F-Droid (Android client)
#          -> Pangolin (fdroid.marcpartensky.com, SSO DISABLED)
#          -> newt (site tower)
#          -> 127.0.0.1:8093 (nginx, serves /var/lib/fdroid/repo)
#
# Why SSO disabled: an F-Droid repository is read by a native client that does
# not know how to follow a login redirect. It makes anonymous GETs on
# index-v2.json, index-v1.jar and the APKs. The repository therefore contains only
# public artifacts (signed release APKs): no secret goes through.
#
# Signature: the repository key (JKS keystore) is the ONLY secret, stored encrypted
# in secrets/fdroid.yml (tower recipient) and placed in /var/lib/fdroid by
# the publish unit. If it is lost, clients must delete
# then re-add the repository (new fingerprint): the keystore backup
# is secrets/fdroid.yml in the git repo.
#
# Publication: drop an APK in /var/lib/fdroid/incoming (mailbox
# sticky 1777, so without sudo or group membership). The path unit
# fdroid-repo-publish.path triggers fdroid-repo-publish.service, which moves
# the APK into repo/, regenerates the indexes (v1 + v2) and signs them. Journal:
# journalctl -u fdroid-repo-publish.
#
# Per-application metadata (name, description, categories, screenshots):
# /var/lib/fdroid/metadata/<package>.yml, editable by marc (fdroid group).
# `fdroid update --create-metadata` only creates the missing skeletons, so
# an existing file is never overwritten.
#
# Managed versions: a more recent APK of the same package is added to the index alongside
# the previous ones (Droidify offers the update), provided it is signed by
# the SAME application key as the already published APK (otherwise Android refuses
# the install on top).
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

  # Privileged step: tree, config.yml (keystore password) and
  # keystore decoding. Runs as root via the "+" prefix of ExecStartPre.
  prepare = pkgs.writeShellApplication {
    name = "fdroid-repo-prepare";
    runtimeInputs = [pkgs.coreutils pkgs.bash pkgs.findutils];
    text = ''
      set -eu

      install -d -o fdroid -g fdroid -m 0755 ${stateDir}
      install -d -o fdroid -g fdroid -m 0755 ${repoDir} ${repoDir}/icons
      install -d -o fdroid -g fdroid -m 0775 ${metadataDir}
      # Mailbox: sticky 1777 so that marc and the hermes agent can
      # drop an APK there without sudo or membership in the fdroid group. The sticky
      # bit prevents fdroid from renaming a file dropped by another
      # user: its ownership is given to it here (we run as root).
      install -d -m 1777 ${incomingDir}
      find ${incomingDir} -maxdepth 1 -type f -name '*.apk' -exec chown fdroid:fdroid {} +

      install -o fdroid -g fdroid -m 0600 \
        ${config.sops.templates."fdroid-config.yml".path} ${stateDir}/config.yml

      if [ ! -r /run/secrets/fdroid_keystore_b64 ]; then
        echo "fdroid_keystore_b64 secret unreadable" >&2
        exit 1
      fi
      tmp=$(mktemp ${stateDir}/.keystore.XXXXXX)
      base64 -d < /run/secrets/fdroid_keystore_b64 > "$tmp"
      chown fdroid:fdroid "$tmp"
      chmod 0600 "$tmp"
      mv -f "$tmp" ${stateDir}/keystore.jks

      # Repository icon: fdroid copies it itself into repo/icons/icon.png, so
      # the source must be OUTSIDE the repo folder (otherwise SameFileError).
      install -o fdroid -g fdroid -m 0644 ${./repo-icon.png} ${stateDir}/icon.png
    '';
  };

  # Non-privileged step: APK ingestion + regeneration/signature.
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
          echo "ingesting: $(basename "$f")"
          mv -f "$f" ${repoDir}/
        done
      fi

      # --create-metadata: metadata skeleton for every new package,
      # the already present files are not touched.
      fdroid update --create-metadata

      # Default category of the skeletons = name of the current folder ("fdroid"),
      # invalid on the F-Droid side: we replace it then regenerate the index.
      fixed=$(python3 ${./fix-categories.py})
      if [ -n "$fixed" ]; then
        echo "default category replaced for: $fixed"
        fdroid update
      fi

      echo "repository regenerated: $(ls -l ${repoDir}/index-v2.json)"
    '';
  };
in {
  users.groups.fdroid = {};
  users.users.fdroid = {
    isSystemUser = true;
    group = "fdroid";
    home = stateDir;
    description = "Personal F-Droid repository";
  };
  # marc edits the metadata and drops APKs without sudo.
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

  # Repository config.yml: the keystore password cannot be in
  # clear in the nix store, so the file is rendered at activation.
  sops.templates."fdroid-config.yml" = {
    owner = "fdroid";
    group = "fdroid";
    mode = "0600";
    restartUnits = ["fdroid-repo-publish.service"];
    content = ''
      repo_url: https://fdroid.marcpartensky.com/repo
      repo_name: Marc Partensky
      repo_description: Marc's personal Android applications.
      # fdroid combines repo_icon with repo/icons/: value = simple file
      # name, source = icon.png at the root of stateDir (outside the repo folder).
      repo_icon: icon.png
      repo_keyalias: fdroid
      keystore: ${stateDir}/keystore.jks
      keystorepass: ${config.sops.placeholder.fdroid_keystore_pass}
      keypass: ${config.sops.placeholder.fdroid_keystore_pass}
    '';
  };

  # Tree created at boot (before the service starts): the service
  # cannot have WorkingDirectory on a folder that does not exist yet.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 fdroid fdroid -"
    "d ${repoDir} 0755 fdroid fdroid -"
    "d ${repoDir}/icons 0755 fdroid fdroid -"
    "d ${metadataDir} 0775 fdroid fdroid -"
    "d ${incomingDir} 1777 root root -"
  ];

  systemd.services.fdroid-repo-publish = {
    description = "Regenerates and signs the personal F-Droid repository";
    environment = {
      HOME = stateDir;
      # fdroid writes its cache under $HOME/.cache; stateDir belongs to fdroid.
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

  # Automatic trigger as soon as an APK appears in the mailbox.
  systemd.paths.fdroid-repo-publish = {
    wantedBy = ["multi-user.target"];
    pathConfig.DirectoryNotEmpty = incomingDir;
  };

  # Local vhost in loopback HTTP: TLS is carried by Pangolin/newt.
  # Only /repo/ is served (root = stateDir + uri -> stateDir/repo/...): the
  # keystore and config.yml stay out of reach of an HTTP request.
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
      # The indexes and the APKs are rewritten at each publication: no long
      # cache on the proxy side, otherwise a client can see a stale index for
      # hours.
      add_header Cache-Control "public, max-age=300";
    '';
  };

  # Public resource (SSO disabled, cf. header): old schema of this
  # Pangolin -> `proxy-resources` + `protocol` + target `127.0.0.1`.
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
