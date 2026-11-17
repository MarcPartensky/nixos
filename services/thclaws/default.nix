# services/thclaws/default.nix
#
# thClaws : harness d'agent en Rust (GUI + CLI + webapp depuis un seul binaire).
# Le paquet vient du flake du projet /home/marc/git/thclaws (binaire prebuilt
# repackage avec autoPatchelf) ; ici on ne declare que le service.
#
# EXPOSITION (skill selfhosted-remote-access) : thClaws n'a AUCUNE
# authentification propre. Mesure du 13/11/2026 sur la 0.156.0 : `GET /` rend
# 200 sans jeton, meme avec THCLAWS_SERVE_TOKEN pose dans l'environnement. L'UI
# donne un acces bash complet, donc :
#   - le port 8453 n'est PAS dans networking.firewall.allowedTCPPorts : le LAN
#     (wlan0) est ferme, seules les interfaces trusted (tailscale0, ygg, lo)
#     passent ;
#   - l'acces public passe par Pangolin avec SSO (ressource `thclaws` dans
#     services/newt) : c'est Pangolin qui porte l'OIDC Zitadel, pas thClaws ;
#   - le tailnet est le chemin direct, sans auth applicative (identite
#     WireGuard). C'est un choix assume : quiconque est sur le tailnet pilote
#     l'agent.
#
# Postgres : sans objet. thClaws n'a aucune base, son etat est sur disque
# (.thclaws/ dans le repertoire racine : sessions JSONL, settings, KMS). Le
# StateDirectory /var/lib/thclaws est donc la seule persistance a sauvegarder.
{
  config,
  pkgs,
  lib,
  ...
}: let
  thclaws = pkgs.callPackage /home/marc/git/thclaws/package.nix { };

  envFile = "/run/thclaws/env";
  port = 8453;
in {
  # thClaws lit ses cles soit du keychain OS (absent en headless), soit de
  # variables d'environnement. On extrait seulement les trois providers de
  # marc depuis le .env de hermes (meme mecanisme que winnie-ingest-env) : rien
  # de sensible ne part dans le store, et le fichier reste en 0640 sous /run.
  systemd.services.thclaws-env = {
    description = "Extract provider keys for thClaws";
    wantedBy = ["multi-user.target"];
    before = ["thclaws.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -e
      install -d -m 0750 -o hermes -g hermes /run/thclaws
      umask 0027
      : > ${envFile}
      for key in DEEPSEEK_API_KEY OPENROUTER_API_KEY KIMI_API_KEY; do
        ${pkgs.gnugrep}/bin/grep -E "^''${key}=" /var/lib/hermes/.hermes/.env >> ${envFile} || true
      done
      chown hermes:hermes ${envFile}
      chmod 0640 ${envFile}
    '';
  };

  systemd.services.thclaws = {
    description = "thClaws agent harness (webapp)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "thclaws-env.service"];
    wants = ["network-online.target" "thclaws-env.service"];

    environment = {
      # Derriere le reverse proxy qui authentifie (Pangolin/badger) : c'est le
      # mode prevu par upstream pour ce montage.
      THCLAWS_SERVE_BEHIND_PROXY = "1";
      THCLAWS_EXTERNAL_URL = "https://thclaws.marcpartensky.com";
    };

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      # Racine du sandbox de fichiers de l'agent (ch.3 du manuel : tous les
      # outils read/write/edit/bash sont confines a ce repertoire).
      StateDirectory = "thclaws";
      StateDirectoryMode = "0750";
      WorkingDirectory = "/var/lib/thclaws";
      EnvironmentFile = envFile;
      # StateDirectory cree /var/lib/thclaws, mais systemd resout
      # WorkingDirectory au moment du chdir : on le cree explicitement avant.
      ExecStartPre = "+${pkgs.coreutils}/bin/mkdir -p /var/lib/thclaws";
      ExecStart = "${thclaws}/bin/thclaws --serve --port ${toString port} --bind 0.0.0.0";
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
      KillMode = "mixed";

      # L'agent doit pouvoir lancer les commandes systeme de marc (dont
      # `sudo nixos-rebuild`, NOPASSWD cote hermes) : pas de NoNewPrivileges.
      NoNewPrivileges = false;
      PrivateTmp = true;
      ProtectHome = false;
      ProtectSystem = false;
    };
  };
}
