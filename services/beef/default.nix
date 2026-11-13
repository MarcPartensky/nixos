# services/beef/default.nix
# BeEF (Browser Exploitation Framework) : labo de hook navigateur.
#
# Trois briques, chacune avec sa raison d'etre :
#
#   beef (3010, loopback)          le framework. Construit depuis un commit
#                                  epingle : BeEF n'est pas dans nixpkgs et
#                                  l'image Docker officielle est figee a
#                                  octobre 2022 (0.5.x, avant la 0.6.0.0).
#                                  Console d'operateur sur /ui/panel.
#   beef-lure-filter (3011)        relais qui sert le leurre et /hook.js et
#                                  refuse /ui et /api. Indispensable : un tunnel
#                                  sortant arrive par la loopback, donc les
#                                  restrictions d'IP de BeEF ne peuvent pas
#                                  separer le public du local.
#   cloudflared-lure               tunnel rapide Cloudflare (nom aleatoire
#                                  *.trycloudflare.com, aucun compte, aucun
#                                  domaine a marc) pointe sur le filtre. Le nom
#                                  change a chaque demarrage : d'ou
#                                  beef-render-config (regenere config.yaml
#                                  avec l'URL courante) et beef-tunnel-sync
#                                  (redemarre beef quand le nom a change).
#
# Exposition :
#   - console : https://beef.marcpartensky.com (SSO Pangolin/Zitadel) -> 3010.
#     NB : `auth.sso-enabled` gate la ressource, mais le blueprint ne porte pas
#     de champ pour aller directement a l'IdP ; `resources.skipToIdpId` est pose
#     en base Pangolin comme pour navidrome et aonsoku, sinon la page de login
#     interne du proxy s'affiche avant Zitadel.
#   - leurre : l'URL du tunnel, a diffuser par un lien court Shlink (voir le
#     skill short-link-operations) et a ne jamais publier ailleurs.
#
# Rien n'est ouvert au firewall : les deux ports restent en loopback.
{
  config,
  lib,
  pkgs,
  ...
}: let
  port = 3010;
  filterPort = 3011;
  domain = "beef.marcpartensky.com";
  stateDir = "/var/lib/beef";

  # Groupes du Gemfile.lock installes. Le groupe `test` est le seul exclu : ses
  # gems (capybara, selenium, curb, geckodriver-helper...) ne servent pas au
  # runtime et sont les plus fragiles a construire. Les groupes d'extensions
  # sont installes parce que des gems du groupe default en dependent
  # (msgpack <- msfrpc-client en ext_msf) : les exclure retire ces gems du load
  # path de bundler et BeEF meurt au require de loader.rb.
  withoutGroups = "test";
  installedGroups = ["default" "geoip" "ext_msf" "ext_notifications" "ext_dns" "ext_qrcode"];

  # Source epinglee (master du 11/11/2026). gemset.nix est genere par bundix
  # depuis le Gemfile.lock de ce meme commit ; le bump des deux va ensemble.
  src = pkgs.fetchFromGitHub {
    owner = "beefproject";
    repo = "beef";
    rev = "22ee2e4feee5144464e1887d764be7732edb3eb4";
    hash = "sha256-KJiKC2p45T2HCR7SZ8ZEUKibb1yJxok1EBDbGwXQj9k=";
  };

  # Source + gemset.nix : ce dossier sert a la fois de gemdir a bundlerEnv et de
  # racine applicative (BeEF calcule ses chemins depuis __FILE__).
  beefSrc = pkgs.runCommand "beef-src-0.6.0.0" {nativeBuildInputs = [pkgs.python3];} ''
    cp -r ${src}/. $out
    chmod -R u+w $out
    cp ${./gemset.nix} $out/gemset.nix
    # Le lockfile upstream ne liste que des variantes de plateforme
    # (x86_64-linux-gnu, aarch64-linux-musl, arm64-darwin...) que nixpkgs ne
    # construit pas : bundler echoue au demarrage sur « Could not find
    # sqlite3-2.10.2-x86_64-linux-gnu in locally installed gems ». On ramene
    # les specs a la version generique et PLATFORMS a `ruby`, ce que bundlerEnv
    # fournit exactement. Fait ICI et pas dans le lanceur : bundlerEnv fige sa
    # propre copie (gemfile-and-lockfile) a la construction.
    python3 ${./fix-lockfile.py} $out/Gemfile.lock
    # Les pages de demonstration sont desactivees en amont : le leurre
    # /demos/basic.html vient de la.
    substituteInPlace $out/extensions/demos/config.yaml \
      --replace-fail "enable: false" "enable: true"
    # Jeton d'API REST deterministe : BeEF en genere un aleatoire a chaque
    # demarrage et ne le persiste nulle part (ni en base, ni dans un fichier),
    # donc aucun client REST (le MCP) ne pourrait s'authentifier. Le module
    # alimente BEEF_API_TOKEN depuis un secret sops.
    substituteInPlace $out/core/main/crypto.rb \
      --replace-fail "token = SecureRandom.random_bytes(token_length).unpack1('H*')" \
      "token = ENV.fetch('BEEF_API_TOKEN') { SecureRandom.random_bytes(token_length).unpack1('H*') }"
    # Le lanceur calcule le dossier des migrations en RELATIF au repertoire
    # courant, alors que le service tourne dans /var/lib/beef (la base beef.db
    # doit rester inscriptible, le store nix ne l'est pas). Sans ce patch :
    # aucune migration appliquee, puis « Could not update 'beef.db' database
    # file: Could not find table 'command_modules' » au premier demarrage.
    substituteInPlace $out/beef \
      --replace-fail "ActiveRecord::Migrator.migrations_paths = [File.join('core', 'main', 'ar-migrations')]" \
      "ActiveRecord::Migrator.migrations_paths = ['$out/core/main/ar-migrations']"
    # Rack::Protection::HostAuthorization n'autorise que *.localhost, *.test, les
    # IP litterales et beef.http.public.host (l'hote du tunnel du leurre) : la
    # console arrive avec le Host de son domaine (SSO Pangolin) et chaque appel
    # API repond alors 403 « Host not permitted ». On autorise en plus l'hote
    # de la console, passe par BEEF_CONSOLE_HOST depuis le lanceur.
    substituteInPlace $out/core/main/router/router.rb \
      --replace-fail "          permitted << public_host unless public_host.empty?" \
      "          permitted << public_host unless public_host.empty?
          console_host = ENV['BEEF_CONSOLE_HOST'].to_s.strip
          permitted << console_host unless console_host.empty?"
  '';

  beefEnv = pkgs.bundlerEnv {
    name = "beef-0.6.0.0-gems";
    gemdir = beefSrc;
    ruby = pkgs.ruby_3_4;
    groups = installedGroups;
    # nokogiri 1.19.5 : deux pieges de construction.
    #   - `--use-system-libraries` en buildFlag ne suffit pas (extconf retombe
    #     sur mini_portile2, absent du sandbox et de toute facon sans reseau) :
    #     la variable d'environnement, equivalente documentee, est bien lue.
    #   - libgumbo n'a PAS de variante systeme : sans `--gumbo-dev`, extconf le
    #     compile via mini_portile2 et echoue. Avec ce flag il compile les
    #     sources gumbo-parser embarquees dans la gem.
    gemConfig = pkgs.defaultGemConfig // {
      nokogiri = attrs: let
        base = pkgs.defaultGemConfig.nokogiri attrs;
      in
        base
        // {
          buildFlags = (base.buildFlags or []) ++ ["--gumbo-dev"];
          preBuild = ''
            export NOKOGIRI_USE_SYSTEM_LIBRARIES=1
          '';
          nativeBuildInputs = (base.nativeBuildInputs or []) ++ [pkgs.pkg-config];
          buildInputs = (base.buildInputs or []) ++ [pkgs.libxml2 pkgs.libxslt pkgs.zlib];
        };
    };
  };

  # nodejs : uglifier passe par execjs et minifie le JS au demarrage.
  # espeak-ng : module text_to_voice.
  beef = pkgs.writeShellApplication {
    name = "beef";
    runtimeInputs = [pkgs.nodejs pkgs.espeak-ng];
    text = ''
      export HOME=${stateDir}
      export BUNDLE_GEMFILE=${beefSrc}/Gemfile
      export BUNDLE_WITHOUT='${withoutGroups}'
      # Host autorise pour la console d'operateur (voir le patch de
      # core/main/router/router.rb) : son domaine n'est pas celui du leurre.
      export BEEF_CONSOLE_HOST='${domain}'
      # Jeton d'API REST fixe, lu depuis le secret sops : sans lui BeEF en
      # genere un aleatoire a chaque demarrage et le client REST (beef-mcp) ne
      # pourrait plus s'authentifier.
      if [ ! -r ${config.sops.secrets.beef_api_token.path} ]; then
        echo "beef: jeton d'API illisible (${config.sops.secrets.beef_api_token.path})" >&2
        exit 1
      fi
      BEEF_API_TOKEN="$(cat ${config.sops.secrets.beef_api_token.path})"
      export BEEF_API_TOKEN
      # L'arbre doit etre INSCRIPTIBLE : au demarrage BeEF minifie le JS de sa
      # console et l'ecrit dans extensions/admin_ui/media/javascript-min/, ce
      # qui est impossible depuis le store nix (« Read-only file system »). On
      # travaille donc sur une copie dans le repertoire d'etat, refaite a chaque
      # demarrage ; la base vit a cote (chemin absolu pose par render-config).
      src="${stateDir}/src"
      rm -rf "$src"
      mkdir -p "$src"
      cp -r --no-preserve=mode ${beefSrc}/. "$src/"
      chmod -R u+w "$src"
      cd "$src"
      exec ${beefEnv.wrappedRuby}/bin/ruby "$src/beef" -d -c ${stateDir}/config.yaml
    '';
  };

  lureFilter = pkgs.writeShellApplication {
    name = "beef-lure-filter";
    runtimeInputs = [pkgs.python3];
    text = ''
      exec python3 ${./lure-filter.py}
    '';
  };

  renderConfig = pkgs.writeShellApplication {
    name = "beef-render-config";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused];
    text = builtins.readFile ./render-config.sh;
  };

  tunnelSync = pkgs.writeShellApplication {
    name = "beef-tunnel-sync";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.systemd];
    text = builtins.readFile ./tunnel-sync.sh;
  };

  checkLogin = pkgs.writeShellApplication {
    name = "beef-check-login";
    runtimeInputs = [pkgs.coreutils pkgs.curl];
    text = builtins.readFile ./check-login.sh;
  };
in {
  # La derivation est exposee pour pouvoir la builder hors tower :
  #   nix build --impure --expr '...config.system.build.beef'
  system.build.beef = beef;

  sops.secrets.beef_admin_password = {
    key = "beef_admin_password";
    sopsFile = ../../secrets/beef.yml;
    owner = "beef";
    mode = "0400";
  };

  # Lu par le service beef (owner) et par le MCP beef-mcp (groupe hermes) :
  # c'est le meme jeton des deux cotes, d'ou le 0440.
  sops.secrets.beef_api_token = {
    key = "beef_api_token";
    sopsFile = ../../secrets/beef.yml;
    owner = "beef";
    group = "hermes";
    mode = "0440";
    restartUnits = ["beef.service"];
  };

  users.groups.beef = {};
  users.users.beef = {
    isSystemUser = true;
    group = "beef";
    home = stateDir;
  };

  systemd.services.beef-lure-filter = {
    description = "Filtre public du leurre BeEF (console et API refusees)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    environment = {
      BEEF_BACKEND_PORT = toString port;
      BEEF_FILTER_PORT = toString filterPort;
      BEEF_FILTER_LOG = "${stateDir}/lure-filter-access.log";
    };
    serviceConfig = {
      User = "beef";
      Group = "beef";
      StateDirectory = "beef";
      ExecStart = "${lureFilter}/bin/beef-lure-filter";
      Restart = "always";
      RestartSec = 3;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  systemd.services.cloudflared-lure = {
    description = "Tunnel rapide Cloudflare vers le filtre du leurre BeEF";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "beef-lure-filter.service"];
    wants = ["network-online.target" "beef-lure-filter.service"];
    serviceConfig = {
      User = "beef";
      Group = "beef";
      StateDirectory = "beef";
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${toString filterPort} --logfile ${stateDir}/cloudflared.log";
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
    };
  };

  systemd.services.beef = {
    description = "BeEF (Browser Exploitation Framework), labo de hook navigateur";
    wantedBy = ["multi-user.target"];
    after = ["cloudflared-lure.service" "beef-lure-filter.service"];
    wants = ["cloudflared-lure.service"];
    environment = {
      BEEF_STATE_DIR = stateDir;
      BEEF_SRC_CONFIG = "${beefSrc}/config.yaml";
      BEEF_PASSWORD_FILE = config.sops.secrets.beef_admin_password.path;
      BEEF_PORT = toString port;
    };
    serviceConfig = {
      User = "beef";
      Group = "beef";
      StateDirectory = "beef";
      WorkingDirectory = stateDir;
      # Attend le nom du tunnel puis ecrit config.yaml (public.host, mot de
      # passe, loopback) et verifie le resultat avant de rendre la main.
      ExecStartPre = "${renderConfig}/bin/beef-render-config";
      ExecStart = "${beef}/bin/beef";
      Restart = "always";
      RestartSec = 5;
      TimeoutStartSec = 300;
    };
  };

  # Le nom du tunnel rapide change a chaque redemarrage de cloudflared : ce
  # timer compare le nom courant a celui rendu dans la config et redemarre beef
  # si besoin (son ExecStartPre regenere alors la config).
  systemd.services.beef-tunnel-sync = {
    description = "Realigne BeEF sur le nom courant du tunnel rapide";
    environment.BEEF_STATE_DIR = stateDir;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${tunnelSync}/bin/beef-tunnel-sync";
    };
  };

  systemd.timers.beef-tunnel-sync = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "1min";
    };
  };

  # Verifie que la console accepte VRAIMENT les identifiants de la config : le
  # seul symptome d'un mot de passe mal pose est un « login impossible » cote
  # navigateur, sans rien dans les journaux. Ce controle rejoue le login depuis
  # un process qui peut lire le secret (User=beef) et journalise le verdict.
  # Lance par un timer, pas par beef.service : un ExecStartPost bloquant
  # retarderait l'etat « started » du service.
  systemd.services.beef-selfcheck = {
    description = "Verifie que la console BeEF accepte les identifiants de la config";
    after = ["beef.service"];
    wants = ["beef.service"];
    environment = {
      BEEF_CONSOLE_URL = "http://127.0.0.1:${toString port}";
      BEEF_USER = "beef";
      BEEF_PASSWORD_FILE = config.sops.secrets.beef_admin_password.path;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "beef";
      Group = "beef";
      StateDirectory = "beef";
      ExecStart = "${checkLogin}/bin/beef-check-login";
    };
  };

  systemd.timers.beef-selfcheck = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min";
    };
  };

  # Console d'operateur : domaine a marc, SSO en amont. Le leurre ne passe pas
  # par ici (il passe par le tunnel et le filtre), donc aucun conflit de
  # chemin : Pangolin ne sait pas decouper une ressource par path.
  services.newt.blueprint.proxy-resources.beef = {
    name = "beef";
    protocol = "http";
    full-domain = domain;
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
          # /hook.js repond 200 sans authentification ; "/" rend 404, ce qui
          # sortirait la cible du load-balancer.
          path = "/hook.js";
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

  assertions = [
    {
      assertion =
        !(lib.elem port config.networking.firewall.allowedTCPPorts)
        && !(lib.elem filterPort config.networking.firewall.allowedTCPPorts);
      message = "beef : les ports ${toString port} et ${toString filterPort} doivent rester en loopback (exposition par le tunnel et Pangolin uniquement).";
    }
  ];
}
