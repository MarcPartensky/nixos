# Module temporaire : active Winnie depuis le flake du projet.
#
# Ecarts assumes par rapport a la source de verite, a supprimer apres :
# 1. Le code Rust du working tree ne compile pas (backend/src reference
#    `winnie_backend::router` alors que la crate ne l'expose pas), donc le
#    package Nix du flake est inutilisable : on epingle le binaire compile par
#    cargo. Nix le copie dans le store, ce qui le protege du ramasse-miettes.
# 2. Le service backend est redeclare ici au lieu d'importer
#    `nixosModules.default`, qui tirerait ce package cassable.
# 3. Garage/S3 est desactive : le module du projet declare un groupe `garage`
#    statique que le DynamicUser du service garage de nixpkgs refuse
#    ("User or group with specified name already exists"), et une fois ce point
#    contourne le service echoue en 70 ms (dossiers /var/lib/garage/{meta,data}
#    absents). Le backend tourne sans S3 : s3.env est optionnel, seules les
#    routes media sont indisponibles.
# L'infrastructure (user/groupe winnie, base PostgreSQL + schema, secret JWT)
# vient bien du projet via l'import ci-dessous.
{ pkgs, lib, ... }:
let
  backendBin = pkgs.runCommand "winnie-backend-pinned" { } ''
    install -Dm755 ${/home/marc/git/winnie/backend/target/release/winnie-backend} $out/bin/winnie-backend
  '';
in {
  imports = [ /home/marc/git/winnie/services/winnie/default.nix ];

  services.winnie.manageGarage = false;

  # winnie-bucket n'est pas conditionne par manageGarage dans le module du
  # projet : sans Garage il echoue, on empeche son demarrage au boot.
  systemd.services.winnie-bucket.wantedBy = lib.mkForce [ ];

  # Front Dioxus (web statique) : build `app/ui/build.sh` -> app/ui/dist, copie
  # dans le store a l'evaluation, servi en loopback ; Pangolin l'expose sur
  # winnie.marcpartensky.com. Rebuild du front = relancer build.sh puis switch.
  systemd.services.winnie-frontend = {
    description = "Winnie front (Dioxus web, statique)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.static-web-server}/bin/static-web-server"
        "--host 127.0.0.1"
        "--port 8080"
        "--root ${builtins.path { path = /home/marc/git/winnie/app/ui/dist; name = "winnie-ui-dist"; }}"
        "--page-fallback ${builtins.path { path = /home/marc/git/winnie/app/ui/dist/index.html; name = "winnie-ui-index.html"; }}"
        "--health"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.services.winnie-backend = {
    description = "Winnie backend (Rust/Axum, binaire epingle)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "postgresql.service"
      "winnie-schema.service"
      "winnie-jwt-secret.service"
      "network.target"
    ];
    requires = [ "postgresql.service" "winnie-jwt-secret.service" ];
    serviceConfig = {
      User = "winnie";
      Group = "winnie";
      WorkingDirectory = "/var/lib/winnie";
      # jwt.env est obligatoire, s3.env optionnel : sans S3 les routes media
      # renvoient une erreur, le reste de l'API fonctionne.
      EnvironmentFile = [ "/var/lib/winnie/jwt.env" "-/var/lib/winnie/s3.env" ];
      Environment = [
        "DATABASE_URL=postgresql://winnie@127.0.0.1/winnie"
        "SERVER_HOST=127.0.0.1"
        "SERVER_PORT=8787"
        "RUST_LOG=info"
        "RESTAURANTS_JSON=${/home/marc/git/winnie/data/restaurants.json}"
        "CHAT_BACKEND=openrouter"
      ];
      ExecStart = "${backendBin}/bin/winnie-backend";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
