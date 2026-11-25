# Service rentscout : UI web + scrape planifié.
#
# Le code vit pour l'instant dans /var/lib/hermes/workspace/rentscout (hermes n'a
# pas le droit d'ecrire dans /home/marc/git). Des que le dossier
# /home/marc/git/rentscout existe avec son ACL, ce module doit importer le
# module du projet (builtins.getFlake -> nixosModules.default) au lieu de
# declarer les unites ici, comme services/winnie.
{ config, pkgs, lib, ... }:
let
  projectDir = /var/lib/hermes/workspace/rentscout;
  rentscout = pkgs.stdenvNoCC.mkDerivation {
    pname = "rentscout";
    version = "0.1.0";
    src = lib.cleanSource projectDir;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/lib $out/share/rentscout
      cp -r rentscout $out/lib/
      cp services/rentscout/schema.sql $out/share/rentscout/
      makeWrapper ${pkgs.python3.withPackages (ps: [ ps.psycopg ps.websockets ])}/bin/python \
        $out/bin/rentscout --add-flags "-m rentscout" --prefix PYTHONPATH : $out/lib
    '';
  };
  schema = "${rentscout}/share/rentscout/schema.sql";
  env = {
    RENTSCOUT_DATABASE_URL = "postgresql://rentscout@127.0.0.1:5432/rentscout";
    # chromium du desktop Kasm (CDP) : sans lui, seules les annonces SpareRoom
    # descendent (elles passent en HTTP simple).
    RENTSCOUT_CDP_URL = "http://127.0.0.1:9224";
  };
in {
  # Utilisateur système + groupe (le rôle Postgres homonyme est déclaré plus bas :
  # deux espaces de noms différents, cf. services/taskq).
  users.groups.rentscout = { };
  users.users.rentscout = {
    isSystemUser = true;
    group = "rentscout";
    description = "rentscout scrape + web UI";
  };

  # Ressource Pangolin declaree ici (blueprint newt) et pas via l'API : newt
  # 1.17 n'applique que ce que le blueprint contient, une ressource creee par
  # l'API reste en 503 (verifie le 2026-11-03 : target creee, health jamais
  # sonder, aucun log cote newt).
  # SSO desactive a la demande de marc (2026-11-03) : la page ne contient que
  # des annonces publiques, rien de personnel.
  services.newt.blueprint.proxy-resources.rentscout = {
    name = "rentscout";
    protocol = "http";
    full-domain = "rentscout.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8795;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8795;
          path = "/healthz";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  systemd.services.rentscout-schema = {
    description = "rentscout: apply idempotent schema";
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; User = "rentscout"; RemainAfterExit = true; };
    script = "${config.services.postgresql.package}/bin/psql -h 127.0.0.1 -U rentscout -d rentscout -v ON_ERROR_STOP=1 -q -f ${schema}";
  };

  systemd.services.rentscout-web = {
    description = "rentscout web UI";
    after = [ "rentscout-schema.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "rentscout-schema.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = env;
    serviceConfig = {
      User = "rentscout";
      ExecStart = "${rentscout}/bin/rentscout serve 8795";
      Restart = "on-failure";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  systemd.services.rentscout-scrape = {
    description = "rentscout: scrape SpareRoom and RentHop";
    after = [ "rentscout-schema.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = env;
    serviceConfig = {
      Type = "oneshot";
      User = "rentscout";
      ExecStart = "${rentscout}/bin/rentscout scrape all";
      TimeoutStartSec = "2h";
    };
  };

  systemd.timers.rentscout-scrape = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 08,20:05:00"; Persistent = true; RandomizedDelaySec = "10m"; };
  };
}
