# Proton Mail MCP pour NixOS
#
# - packages.<system>.default : proton-mail-bridge-client (serveur MCP + CLI)
#   https://github.com/googlarz/proton-mail-bridge-client
# - nixosModules.default : Proton Mail Bridge headless (service système)
#   + entrée MCP prête à brancher dans Hermes
#
# Flake local (sous-dossier de ce repo), branché en path: depuis le flake.nix
# racine (pas de repo GitHub séparé pour l'instant) :
#   inputs.protonmail-mcp.url = "path:./protonmail-mcp";
#   inputs.protonmail-mcp.inputs.nixpkgs.follows = "nixpkgs";
#   modules = [ inputs.protonmail-mcp.nixosModules.default ];
# (déplaçable vers "github:MarcPartensky/<repo>" si ça sort un jour dans son
# propre repo : même wiring, juste changer l'url ci-dessus.)
#
# Sur l'hôte Hermes (Bridge et le MCP doivent tourner sur la même machine) :
#   sops.secrets."protonmail/bridge-password".owner = "hermes";
#   services.protonmail-mcp = {
#     enable = true;
#     username = "marc.partensky@proton.me";
#     passwordFile = config.sops.secrets."protonmail/bridge-password".path;
#   };
#   services.hermes-agent.mcpServers.protonmail = config.services.protonmail-mcp.mcpServer;
#
# Premier login Bridge (une seule fois) : sudo protonmail-bridge-login
#   puis dans le CLI : login, info (copier le mot de passe Bridge dans sops), exit
{
  description = "Proton Mail MCP (proton-mail-bridge-client) + Proton Mail Bridge headless";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    proton-mail-bridge-client = {
      url = "github:googlarz/proton-mail-bridge-client";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      proton-mail-bridge-client,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPackage =
        pkgs:
        pkgs.callPackage (
          {
            lib,
            stdenv,
            buildNpmPackage,
            importNpmLock,
          }:
          let
            src = proton-mail-bridge-client;
            package = lib.importJSON "${src}/package.json";
            lock = lib.importJSON "${src}/package-lock.json";
            # TypeScript 7 = un binaire natif par plateforme (~10 Mo chacun, 20 plateformes) :
            # on ne garde que celui de la machine qui build
            tsPrefix = "node_modules/@typescript/typescript-";
            tsPlatform =
              {
                x86_64-linux = "linux-x64";
                aarch64-linux = "linux-arm64";
                aarch64-darwin = "darwin-arm64";
              }
              .${stdenv.hostPlatform.system};
          in
          buildNpmPackage {
            pname = package.name;
            inherit (package) version;
            inherit src;

            # Deps lues depuis package-lock.json : aucun hash à maintenir,
            # `nix flake update` suffit pour monter de version
            npmDeps = importNpmLock {
              inherit package;
              packageLock = lock // {
                packages = lib.filterAttrs (
                  name: _: !(lib.hasPrefix tsPrefix name) || name == tsPrefix + tsPlatform
                ) lock.packages;
              };
            };
            npmConfigHook = importNpmLock.npmConfigHook;

            # better-sqlite3 compilé depuis les sources (pas de réseau dans le sandbox)
            env.npm_config_build_from_source = "true";
            # le script "prepare" relancerait tsc pendant `npm pack`
            npmPackFlags = [ "--ignore-scripts" ];

            meta = {
              description = "MCP server and CLI for Proton Mail through Proton Mail Bridge";
              homepage = "https://github.com/googlarz/proton-mail-bridge-client";
              license = lib.licenses.mit;
              mainProgram = "proton-mail-bridge-mcp";
              platforms = systems;
            };
          }
        ) { };
    in
    {
      packages = forAllSystems (pkgs: rec {
        proton-mail-bridge-client = mkPackage pkgs;
        default = proton-mail-bridge-client;
      });

      overlays.default = final: _prev: {
        proton-mail-bridge-client = mkPackage final;
      };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.protonmail-mcp;
          user = "protonmail-bridge";
          home = "/var/lib/protonmail-bridge";

          # Premier login : coupe le service et ouvre le CLI Bridge sous l'utilisateur dédié
          loginHelper = pkgs.writeShellApplication {
            name = "protonmail-bridge-login";
            runtimeInputs = [
              pkgs.coreutils
              config.systemd.package
            ];
            text = ''
              if [ "$(id -u)" -ne 0 ]; then
                echo "À lancer avec sudo" >&2
                exit 1
              fi
              systemctl stop protonmail-bridge.service
              trap 'systemctl start protonmail-bridge.service' EXIT
              echo "CLI Bridge : login, puis info (mot de passe à mettre dans sops), puis exit"
              systemd-run --pty --wait --collect --quiet \
                --uid=${user} --gid=${user} \
                --setenv=HOME=${home} \
                --setenv=PATH=${
                  lib.makeBinPath [
                    pkgs.pass
                    pkgs.gnupg
                  ]
                } \
                ${lib.getExe cfg.bridgePackage} --cli
            '';
          };
        in
        {
          options.services.protonmail-mcp = {
            enable = lib.mkEnableOption "Proton Mail Bridge headless et le serveur MCP proton-mail-bridge-client";

            package = lib.mkOption {
              type = lib.types.package;
              default = mkPackage pkgs;
              defaultText = lib.literalMD "`proton-mail-bridge-client` construit par ce flake";
              description = "Paquet du serveur MCP.";
            };

            bridgePackage = lib.mkPackageOption pkgs "protonmail-bridge" { };

            username = lib.mkOption {
              type = lib.types.str;
              example = "you@proton.me";
              description = "Adresse Proton (identifiant IMAP/SMTP de Bridge).";
            };

            passwordFile = lib.mkOption {
              type = lib.types.str;
              example = "/run/secrets/protonmail/bridge-password";
              description = "Fichier contenant le mot de passe généré par Bridge (commande info du CLI), pas celui du compte Proton. Doit être lisible par le client MCP.";
            };

            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              example = {
                PROTONMAIL_ALLOW_SEND = "true";
                PROTONMAIL_RESTRICT_OUTBOUND_TO_SELF = "true";
              };
              description = "Variables PROTONMAIL_* supplémentaires, prioritaires sur les garde-fous par défaut.";
            };

            mcpServer = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              readOnly = true;
              defaultText = lib.literalMD "`command` + `env` dérivés des options ci-dessus";
              description = "Entrée MCP stdio prête à l'emploi, pour services.hermes-agent.mcpServers.";
              default = {
                command = lib.getExe cfg.package;
                env = {
                  PROTONMAIL_USERNAME = cfg.username;
                  PROTONMAIL_PASSWORD_FILE = cfg.passwordFile;
                  # Garde-fous (l'agent lit des mails écrits par n'importe qui) :
                  # lecture + brouillons, ni envoi ni suppression, 25 outils au lieu de 96
                  PROTONMAIL_TOOL_TIER = "core";
                  PROTONMAIL_ALLOW_SEND = "false";
                  PROTONMAIL_ALLOWED_ACTIONS = "mark_read,mark_unread,star,unstar,archive";
                }
                // cfg.environment;
              };
            };
          };

          config = lib.mkIf cfg.enable {
            assertions = [
              {
                assertion = !config.services.protonmail-bridge.enable;
                message = "services.protonmail-mcp lance déjà Proton Bridge : désactive services.protonmail-bridge.";
              }
            ];

            users.users.${user} = {
              isSystemUser = true;
              group = user;
              inherit home;
            };
            users.groups.${user} = { };

            systemd.services.protonmail-bridge = {
              description = "Proton Mail Bridge (headless)";
              wantedBy = [ "multi-user.target" ];
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              path = [
                pkgs.pass
                pkgs.gnupg
              ];
              # Trousseau "pass" exigé par Bridge : clé GPG sans phrase de passe,
              # protégée par les droits 0700 du dossier d'état
              preStart = ''
                if ! gpg --list-secret-keys ${user} >/dev/null 2>&1; then
                  gpg --batch --pinentry-mode loopback --passphrase "" \
                    --quick-gen-key ${user} default default never
                fi
                [ -f "$HOME/.password-store/.gpg-id" ] || pass init ${user}
              '';
              serviceConfig = {
                User = user;
                Group = user;
                StateDirectory = "protonmail-bridge";
                StateDirectoryMode = "0700";
                ExecStart = "${lib.getExe cfg.bridgePackage} --noninteractive";
                Restart = "always";
                RestartSec = 10;
                NoNewPrivileges = true;
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictSUIDSGID = true;
                LockPersonality = true;
              };
            };

            environment.systemPackages = [
              cfg.package
              loginHelper
            ];
          };
        };
    };
}
