{
  config,
  pkgs,
  ...
}:
let
  # Attache (ou crée) une session zellij et l'enregistre avec asciinema, côté serveur.
  # L'enregistrement vit dans le process distant : il survit donc aux reconnexions ET.
  # Variables : ET_RECORD_DIR (défaut ~/recordings/et), ET_RECORD_KEEP_DAYS (défaut 30).
  etSession = pkgs.writeShellApplication {
    name = "et-session";
    runtimeInputs = [
      pkgs.asciinema
      pkgs.zellij
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
        echo "usage: et-session [session zellij]   (défaut : main)"
        exit 0
      fi

      session="''${1:-main}"
      dir="''${ET_RECORD_DIR:-$HOME/recordings/et}"
      keep="''${ET_RECORD_KEEP_DAYS:-30}"
      mkdir -p "$dir"

      # Rotation : purge les enregistrements de CET utilisateur plus vieux que $keep jours
      # (-type f ignore les symlinks latest-*.cast)
      find "$dir" -maxdepth 1 -name '*.cast' -type f -mtime "+$keep" -delete

      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      cast="$dir/$session-$stamp.cast"
      ln -sfn "$cast" "$dir/latest-$session.cast"
      printf 'et-session : session zellij « %s » sur %s, enregistrement -> %s\n' \
        "$session" "$HOSTNAME" "$cast"

      exec asciinema rec --quiet --idle-time-limit 5 \
        --title "et $HOSTNAME $session $stamp" \
        --command "zellij attach --create $session" \
        "$cast"
    '';
  };
in
{
  # Configuration du serveur Eternal Terminal
  services.eternal-terminal = {
    enable = true;

    # Le port par défaut est 2022, tu peux le changer si besoin
    port = 2022;

    # Options facultatives (décommenter pour utiliser) :
    # verbosity = 0;
    # silent = false;
    # logSize = 20971520;
  };

  # Helper de session (`et-session` = zellij + enregistrement asciinema) et asciinema.
  environment.systemPackages = [
    etSession
    pkgs.asciinema
  ];

  # TRÈS IMPORTANT : Ouvrir le port dans le pare-feu pour pouvoir s'y connecter
  networking.firewall.allowedTCPPorts = [config.services.eternal-terminal.port];

  # Désactive la télémétrie (crash reports envoyés à un tiers)
  environment.variables.ET_NO_TELEMETRY = "1";
  systemd.services.eternal-terminal.environment.ET_NO_TELEMETRY = "1";

  # Port ouvert uniquement sur le tailnet Headscale
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    config.services.eternal-terminal.port
  ];
}
