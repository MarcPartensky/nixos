# services/pangolin/default.nix
{config, pkgs, lib, ...}: {
  nixpkgs.config.permittedInsecurePackages = [
    "pangolin-1.10.3"
  ];

  sops.secrets.pangolin_env = {
    sopsFile = ../../secrets/common.yml;
    format = "yaml";
  };

  services.postgresql.ensureDatabases = [ "pangolin" ];
  services.postgresql.ensureUsers = [
    { name = "pangolin"; ensureDBOwnership = true; }
  ];
  services.postgresql.authentication = lib.mkOverride 10 ''
    local   pangolin    pangolin    md5
    local   all         all         peer
  '';

  services.pangolin = {
    enable = true;
    # Patch « stub de licence » (décision marc, 2026-10-23) : les builds
    # open-source compilent server/lib/isLicencedOrSubscribed.ts, un stub figé
    # à `return false` (l'édition oss de nixpkgs supprime même server/private,
    # qui contient la vraie logique réservée aux builds saas/enterprise).
    # Conséquence : toutes les features « gated » — dont les ressources privées
    # http/ssh, nécessaires au P2P nextcloud depuis NYC — renvoient 403
    # "Please upgrade". On remplace le stub par `return true`.
    # À assumer : contourne le gate commercial de Fossorial sur notre instance.
    # Alternative propre si un jour : edition = "enterprise" + une licenseKey.
    package = pkgs.fosrl-pangolin.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace server/lib/isLicencedOrSubscribed.ts \
          --replace-fail 'return false;' 'return true;'
      '';
    });
    baseDomain = "marcpartensky.com";
    dashboardDomain = "pangolin.vps.marcpartensky.com";
    letsEncryptEmail = "marc.partensky@proton.me";
    openFirewall = true;
    environmentFile = config.sops.secrets.pangolin_env.path;
    settings = {
      app = {
        save_logs = true;

      };
      # domains = {
      #   domain1 = {
      #     prefer_wildcard_cert = true;
      #   };
      # };
      server = {
        external_port = 3007;
        internal_port = 3008;
        internal_hostname = "127.0.0.1";
      };
      # API d'intégration v1 (auth par clé Bearer, table apiKeys du
      # dashboard) : utilisée par le MCP pangolin de hermes. Le module ajoute
      # alors le routeur traefik + le service vers localhost:3003, exposés
      # sur api.marcpartensky.com (Host exact, cf. int-api-router du module).
      # Défaut : désactivée.
      flags = {
        enable_integration_api = true;
      };
      postgres = {
        # Pas de mot de passe ici : la vraie connection string arrive par
        # l'environnement du service (variable POSTGRES_CONNECTION_STRING du
        # environmentFile sops ci-dessus, clé "pangolin_env" de
        # secrets/common.yml) et écrase cette valeur au démarrage. Ce fichier
        # part dans le store et le repo (public), donc aucun secret ne doit y
        # figurer, même masqué.
        connection_string = "postgresql://pangolin@127.0.0.1:5432/pangolin";
      };
    };
  };
}
