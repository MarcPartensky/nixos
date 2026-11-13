# modules/nixos/mcp-host/default.nix
# Un seul processus MCP pour tous les serveurs maison.
#
# Probleme mesure : chaque session Hermes lance un processus par serveur (32 par
# session, 133 mesures sur tower), chacun avec son interpreteur Python et sa
# copie du SDK. Cout mesure par processus : 54 Mo de RSS et 910 ms de demarrage,
# dont 33 ms d'interpreteur et 1005 ms d'import du SDK. Les outils inactifs
# finissent en swap et pesent 4 Go.
#
# Ce module lance un demon unique qui monte les serveurs existants sans les
# modifier (shim d'import dans mcp/main.py) et sert le tout sur une seule URL
# loopback, en HTTP streamable. Mesure avec 8 serveurs reels : 90 outils, 85 Mo
# de RSS, 2 processus.
#
# Le code des serveurs reste dans le depot, mais leur liste est figee ici : la
# modifier demande un switch. Les NOUVEAUX outils vont dans le dossier de
# modules (mcp/modules du depot, deploye par `just mcp-deploy`), qui est relu
# sans redemarrer.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.mcp-host;

  pythonEnv = pkgs.python3.withPackages (ps: [ps.fastmcp] ++ cfg.extraPythonPackages);

  # Liste nom -> chemin de fichier .py, consommee par mcp/main.py.
  manifest = pkgs.writeText "mcp-host-servers.json" (builtins.toJSON cfg.servers);
in {
  options.services.mcp-host = {
    enable = lib.mkEnableOption "serveur MCP unique hebergeant les serveurs maison";

    servers = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = lib.literalExpression ''{shlink = ../../services/shlink-mcp/server.py;}'';
      description = ''
        Serveurs existants a monter, sous la forme nom = chemin du fichier
        python. Chaque fichier doit exposer une instance FastMCP dans une
        variable `mcp`, `app` ou `server`. Un fichier qui echoue est ignore et
        journalise, les autres continuent de servir.
      '';
    };

    modulesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mcp/modules";
      description = ''
        Dossier relu a chaque requete pour les outils ajoutes a chaud
        (decorateur `from fastmcp.tools import tool`). C'est la seule partie
        mutable du systeme, alimentee par `just mcp-deploy`.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4780;
      description = "Port loopback du demon. Ne pas ouvrir au firewall : seul Hermes le joint.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = ''
        Utilisateur du demon. Garder `hermes` reproduit les droits actuels des
        serveurs MCP (lances par l'agent) ; passer a `root` seulement si un
        outil a besoin de privileges que hermes n'a pas.
      '';
    };

    extraPythonPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Bibliotheques supplementaires pour les nouveaux modules (httpx, etc.).";
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Variables d'environnement du demon. Indispensable quand des serveurs
        montes lisent leur configuration a l'import (URLs d'API, chemins de
        fichiers de secrets) : ils partagent alors un seul environnement, donc
        il faut l'union de ce que chaque module recevait en stdio.
      '';
    };

    hermesGateway = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bascule les sessions Hermes sur l'URL unique du demon au lieu de lancer
        un processus par serveur. A n'activer qu'apres avoir retire les entrees
        mcpServers en stdio des serveurs concernes : sinon les outils sont
        exposes deux fois, sous deux namespaces differents.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Le dossier des modules doit exister et appartenir a l'utilisateur du
    # demon, sinon le FileSystemProvider ignore ses fichiers en silence.
    systemd.tmpfiles.rules = [
      "d ${cfg.modulesDir} 0755 ${cfg.user} ${cfg.user} -"
    ];

    # Bascule Hermes : une seule entree URL au lieu d'un processus par serveur.
    # Les noms d'outils deviennent mcp__hermes-tools__<outil>, donc toute skill
    # ou cron qui cite un nom complet doit etre mis a jour.
    services.hermes-agent.mcpServers = lib.mkIf cfg.hermesGateway {
      hermes-tools.url = "http://127.0.0.1:${toString cfg.port}/mcp";
    };

    systemd.services.mcp-host = {
      description = "Serveur MCP unique (serveurs maison + modules a chaud)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      environment = {
        MCP_HOST_MANIFEST = "${manifest}";
        MCP_HOST_MODULES = cfg.modulesDir;
        MCP_HOST_PORT = toString cfg.port;
        MCP_HOST_ADDR = "127.0.0.1";
      } // cfg.env;

      serviceConfig = {
        ExecStart = "${pythonEnv}/bin/python ${../../../mcp/main.py}";
        User = cfg.user;
        Group = cfg.user;
        Restart = "always";
        RestartSec = 2;
        # Un outil qui bloque ne doit pas figer la boucle : le SDK execute les
        # outils synchrones dans un threadpool, ce timeout borne le pire cas.
        TimeoutStopSec = 10;
        # Durcissement sans casser les acces fichiers dont les outils ont besoin
        # (secrets sops dans /run/secrets, etat local de certains outils).
        NoNewPrivileges = false;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };
  };
}
