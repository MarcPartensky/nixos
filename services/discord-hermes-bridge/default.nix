# services/discord-hermes-bridge/default.nix
#
# Gateway Hermes dedie, profil "discord-bridge" (cree a la main sur tower via
# `hermes profile create discord-bridge`, meme mecanique que le profil pocket :
# pas de concept d'"instances" dans le module NixOS services.hermes-agent,
# donc unite systemd ecrite a la main ici plutot que via cette option).
#
# Reutilise le MEME paquet hermes-agent (config.services.hermes-agent.package)
# que le bot Matrix @hermes dans services/hermes : meme build, donc les memes
# groupes de deps optionnelles (edge-tts, stt-whisper...) sont deja presents,
# utiles pour la phase 2 (vocal) du pont Discord sans travail supplementaire.
#
# Expose seulement l'API Server OpenAI-compatible (/v1/chat/completions) en
# loopback, consommee par le cog hermes.py du bot (services/discord-bot).
# Jamais de port ouvert au firewall : c'est le meme host, meme boucle locale.
{
  config,
  lib,
  ...
}: let
  package = config.services.hermes-agent.package;
  port = 8643;
in {
  sops.secrets."hermes_discord_bridge_env" = {
    sopsFile = ../../secrets/discord-hermes-bridge.yml;
    owner = "hermes";
    group = "hermes";
  };

  systemd.services.hermes-discord-bridge = {
    description = "Hermes Agent gateway dedie (profil discord-bridge, pont vers discord-bot)";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
      HERMES_MANAGED = "true";
      # API_SERVER_ENABLED/PORT/KEY sont les seules variables documentees
      # (pas de API_SERVER_HOST : le bind loopback 127.0.0.1 est le defaut,
      # non configurable). API_SERVER_KEY vient du fichier sops (EnvironmentFile).
      API_SERVER_ENABLED = "true";
      API_SERVER_PORT = toString port;
    };

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${package}/bin/hermes -p discord-bridge gateway";
      EnvironmentFile = [config.sops.secrets."hermes_discord_bridge_env".path];
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = false;
      ProtectSystem = "strict";
      ReadWritePaths = ["/var/lib/hermes"];
      UMask = "0007";
      WorkingDirectory = "/var/lib/hermes/workspace";
    };
  };

  assertions = [
    {
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "discord-hermes-bridge : le port ${toString port} (API server local) ne doit pas etre ouvert au firewall.";
    }
  ];
}
