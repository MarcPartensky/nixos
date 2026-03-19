{config, ...}: {
  # ── Secrets via SOPS ────────────────────────────────────────────
  # Dans ton anywhere.yml, ajoute :
  #   chhoto_env: |
  #     password=un_mot_de_passe_fort
  #     api_key=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 128)
  sops.secrets."chhoto/env" = {
    key = "chhoto_env";
  };

  # ── Répertoire persistant (SQLite + WAL side-files) ─────────────
  # WAL mode requiert un dossier entier monté, pas un fichier seul
  systemd.tmpfiles.rules = [
    "d /var/lib/chhoto 0750 root root -"
  ];

  # ── Container ───────────────────────────────────────────────────
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.chhoto-url = {
    image = "sintan1729/chhoto-url:latest";
    autoStart = true;

    ports = ["127.0.0.1:4567:4567"];
    volumes = ["/var/lib/chhoto:/data"];

    environment = {
      db_url = "/data/urls.sqlite";
      use_wal_mode = "True";
      site_url = "https://s.vps.marcpartensky.com";
      redirect_method = "PERMANENT";
      slug_style = "UID";
      slug_length = "8";
      try_longer_slug = "True";
      port = "4567";
    };

    # Le fichier SOPS déchiffré contient password= et api_key=
    environmentFiles = [config.sops.secrets."chhoto/env".path];

    extraOptions = [
      "--pull=newer"
      "--health-cmd=curl -sf http://localhost:4567/ || exit 1"
      "--health-interval=30s"
      "--health-timeout=5s"
      "--health-retries=3"
    ];
  };

  systemd.services."podman-chhoto-url" = {
    after = ["network-online.target"];
    wants = ["network-online.target"];
  };
}
